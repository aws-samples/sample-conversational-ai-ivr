"""
build_payment_cart.py (UPDATED — partial payment support)

Changes from previous version:
- Accepts paymentAmount as an explicit input parameter (the amount the customer
  wants to pay, which may be less than the total violation balance)
- Adds FULL and PARTIAL to the accepted paymentType enum
- Auto-determines paymentType from amounts when ambiguous
- Validates paymentAmount > 0 and <= total violation balance
- Stores totalViolationBalance in cart for downstream use
- Backward compatible with old enum values (ALL_PAYABLE, SPECIFIC, etc.)

Env vars:
- SESSION_TABLE_NAME (required)
- CART_TTL_HOURS (optional, default 2)
- LOG_LEVEL (optional)

Payment type normalization map:
  FULL                        → FULL        (new primary)
  PARTIAL                     → PARTIAL     (new primary)
  FULL_BALANCE                → FULL        (legacy → new)
  ALL_PAYABLE                 → FULL        (legacy → new)
  PARTIAL_VIOLATION_SELECTION → PARTIAL     (legacy → new)
  PARTIAL_AMOUNT              → PARTIAL     (legacy → new)
  SPECIFIC                    → PARTIAL     (legacy → new)
"""

import json
import os
import uuid
import logging
from datetime import datetime, timedelta
import decimal

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))

dynamodb = boto3.resource("dynamodb")
SESSION_TABLE_NAME = os.environ["SESSION_TABLE_NAME"]
session_table = dynamodb.Table(SESSION_TABLE_NAME)
TTL_HOURS = int(os.environ.get("CART_TTL_HOURS", "2"))

# ---------------------------------------------------------------------------
# Payment type definitions
# ---------------------------------------------------------------------------

# ◄── CHANGED: Added FULL and PARTIAL to valid set
VALID_PAYMENT_TYPES = {
    "FULL",
    "PARTIAL",
    "ALL_PAYABLE",
    "SPECIFIC",
    "FULL_BALANCE",
    "PARTIAL_VIOLATION_SELECTION",
    "PARTIAL_AMOUNT",
}

# ◄── CHANGED: All values now normalize to FULL or PARTIAL
# Old canonical values (ALL_PAYABLE, SPECIFIC) map to new values
# This ensures downstream Lambdas (UpdateViolationBalance) only
# need to handle two values: FULL and PARTIAL
PAYMENT_TYPE_NORMALIZE = {
    # New primary values (no-op)
    "FULL":                        "FULL",
    "PARTIAL":                     "PARTIAL",
    # Legacy values → new canonical
    "FULL_BALANCE":                "FULL",
    "ALL_PAYABLE":                 "FULL",
    "PARTIAL_VIOLATION_SELECTION": "PARTIAL",
    "PARTIAL_AMOUNT":              "PARTIAL",
    "SPECIFIC":                    "PARTIAL",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _resp(code: int, body: dict):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _parse_body(event):
    """
    Handle both API Gateway proxy events and direct Lambda invocations.
    """
    if isinstance(event, dict) and "body" in event:
        raw = event.get("body") or ""
        if event.get("isBase64Encoded"):
            import base64
            raw = base64.b64decode(raw).decode("utf-8")
        if isinstance(raw, str) and raw.strip():
            return json.loads(raw)
        if isinstance(raw, dict):
            return raw
        return {}
    # Direct invoke – payload is already a dict
    return event if isinstance(event, dict) else {}


def _to_csv_string(value):
    """
    Normalize violationIds or violationAmounts to a clean CSV string.
    """
    if value is None:
        return ""
    if isinstance(value, list):
        csv = ",".join(str(v).strip() for v in value if str(v).strip())
        return csv
    if isinstance(value, str):
        csv = ",".join(v.strip() for v in value.split(",") if v.strip())
        return csv
    return str(value).strip()


def _csv_to_list(csv_string):
    """
    Split a CSV string back into a Python list for iteration.
    """
    if not csv_string:
        return []
    return [v.strip() for v in csv_string.split(",") if v.strip()]


def _sum_csv_amounts(csv_string):
    """
    Sum a CSV string of amounts and return a Decimal.
    """
    total = decimal.Decimal("0")
    for segment in _csv_to_list(csv_string):
        try:
            total += decimal.Decimal(segment)
        except decimal.InvalidOperation:
            logger.warning("Skipping non-numeric amount segment: %r", segment)
    return total  # ◄── CHANGED: return Decimal instead of formatted string


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    req_id = getattr(context, "aws_request_id", "unknown")
    logger.info("buildPaymentCart invoked | requestId=%s", req_id)
    logger.info(
        "SESSION_TABLE_NAME=%s CART_TTL_HOURS=%s",
        SESSION_TABLE_NAME,
        TTL_HOURS,
    )

    # ------------------------------------------------------------------
    # 1. Parse body
    # ------------------------------------------------------------------
    try:
        body = _parse_body(event)
    except Exception as e:
        logger.exception("Invalid JSON body")
        return _resp(400, {"message": "Invalid JSON body", "error": str(e)})

    logger.info("parsed_payload=%s", body)

    # ------------------------------------------------------------------
    # 2. Validate clientId
    # ------------------------------------------------------------------
    client_id = str(body.get("clientId") or "").strip()
    if not client_id:
        return _resp(400, {"message": "Missing clientId"})

    # ------------------------------------------------------------------
    # 3. Validate and normalise paymentType
    # ◄── CHANGED: Accept new FULL/PARTIAL values, auto-determine if missing
    # ------------------------------------------------------------------
    raw_payment_type = str(body.get("paymentType") or "").strip().upper()

    if raw_payment_type and raw_payment_type not in VALID_PAYMENT_TYPES:
        logger.warning(
            "Invalid paymentType received | raw=%r | valid=%s",
            raw_payment_type,
            sorted(VALID_PAYMENT_TYPES),
        )
        return _resp(
            400,
            {
                "message": "Invalid paymentType",
                "received": raw_payment_type,
                "allowed": sorted(VALID_PAYMENT_TYPES),
            },
        )

    # ------------------------------------------------------------------
    # 4. Normalize violationIds and violationAmounts → CSV strings
    # ------------------------------------------------------------------
    violation_ids     = _to_csv_string(body.get("violationIds", ""))
    violation_amounts = _to_csv_string(body.get("violationAmounts", ""))

    logger.info(
        "violationIds (normalized CSV)=%r | violationAmounts (normalized CSV)=%r",
        violation_ids,
        violation_amounts,
    )

    # ------------------------------------------------------------------
    # 5. Session / contact ID resolution
    # ------------------------------------------------------------------
    initial_contact_id = (
        body.get("initialContactId") or body.get("sessionId") or ""
    ).strip()
    if not initial_contact_id:
        return _resp(400, {"message": "Missing sessionId"})

    current_contact_id = (body.get("currentContactId") or "").strip()
    session_id = (body.get("sessionId") or initial_contact_id).strip()

    # ------------------------------------------------------------------
    # 6. Resolve and validate payment amount
    # ◄── CHANGED: Full rewrite of this section
    # ------------------------------------------------------------------
    total_violation_balance = _sum_csv_amounts(violation_amounts)

    payment_amount_raw = str(body.get("paymentAmount") or "").strip()

    if payment_amount_raw:
        # ◄── NEW: paymentAmount was explicitly provided by Nova Sonic
        try:
            payment_amount = decimal.Decimal(payment_amount_raw)
        except decimal.InvalidOperation:
            return _resp(400, {
                "message": f"Invalid paymentAmount: '{payment_amount_raw}'. Must be a numeric value.",
            })

        logger.info(
            "paymentAmount provided explicitly | amount=%s totalViolationBalance=%s",
            payment_amount, total_violation_balance,
        )

        # ◄── NEW: Validate payment amount
        if payment_amount <= decimal.Decimal("0"):
            return _resp(400, {
                "message": "paymentAmount must be greater than zero.",
                "received": str(payment_amount),
            })

        if total_violation_balance > decimal.Decimal("0") and payment_amount > total_violation_balance:
            return _resp(400, {
                "message": (
                    f"paymentAmount ${payment_amount} exceeds total outstanding "
                    f"balance ${total_violation_balance}. "
                    f"Maximum allowed: ${total_violation_balance}."
                ),
                "paymentAmount": str(payment_amount),
                "totalViolationBalance": str(total_violation_balance),
            })
    else:
        # ◄── CHANGED: Fallback still works but logs WARNING instead of INFO
        payment_amount = total_violation_balance
        logger.warning(
            "paymentAmount NOT provided; falling back to total violation balance. "
            "violationAmounts csv=%r → %s. "
            "Partial payment was not possible for this request.",
            violation_amounts,
            payment_amount,
        )

    # Format to 2 decimal places for consistency
    payment_amount_str = f"{payment_amount:.2f}"
    total_balance_str = f"{total_violation_balance:.2f}"

    # ------------------------------------------------------------------
    # 6b. Determine canonical paymentType
    # ◄── NEW: Auto-determine from amounts if not provided or ambiguous
    # ------------------------------------------------------------------
    if raw_payment_type and raw_payment_type in PAYMENT_TYPE_NORMALIZE:
        # Explicit type provided — normalize it
        payment_type = PAYMENT_TYPE_NORMALIZE[raw_payment_type]

        # ◄── NEW: Safety check — if type says FULL but amounts say PARTIAL
        if payment_type == "FULL" and total_violation_balance > decimal.Decimal("0"):
            if payment_amount < total_violation_balance:
                logger.warning(
                    "paymentType=%r (normalized to FULL) but "
                    "paymentAmount=%s < totalViolationBalance=%s. "
                    "Overriding to PARTIAL based on actual amounts.",
                    raw_payment_type, payment_amount, total_violation_balance,
                )
                payment_type = "PARTIAL"

    elif total_violation_balance > decimal.Decimal("0"):
        # ◄── NEW: No type provided — determine from amounts
        if payment_amount >= total_violation_balance:
            payment_type = "FULL"
            raw_payment_type = "FULL"
        else:
            payment_type = "PARTIAL"
            raw_payment_type = "PARTIAL"
        logger.info(
            "paymentType auto-determined from amounts | "
            "paymentAmount=%s totalBalance=%s → type=%s",
            payment_amount, total_violation_balance, payment_type,
        )
    else:
        # No violation amounts and no type — default to FULL
        payment_type = "FULL"
        if not raw_payment_type:
            raw_payment_type = "FULL"

    if raw_payment_type != payment_type:
        logger.info(
            "paymentType normalized | raw=%r → canonical=%r",
            raw_payment_type,
            payment_type,
        )

    # ◄── CHANGED: Validation now uses new canonical values
    if payment_type == "PARTIAL" and not violation_ids:
        logger.warning(
            "PARTIAL paymentType requires violationIds | rawType=%r", raw_payment_type
        )
        return _resp(
            400,
            {
                "message": (
                    f"violationIds are required when paymentType is "
                    f"{raw_payment_type} (resolved to PARTIAL)"
                )
            },
        )

    # ------------------------------------------------------------------
    # 7. Build cart items list from CSV strings
    # ------------------------------------------------------------------
    ids_list     = _csv_to_list(violation_ids)
    amounts_list = _csv_to_list(violation_amounts)

    items = []
    for i, vid in enumerate(ids_list):
        amt = amounts_list[i] if i < len(amounts_list) else ""
        items.append({
            "violationId": vid,
            "amount":      amt,
            "pk":          f"CLIENT#{client_id}#VIOL#{vid}",
            "sk":          "DETAILS",
        })

    # ------------------------------------------------------------------
    # 8. Build DynamoDB cart record
    # ◄── CHANGED: Added totalViolationBalance field
    # ------------------------------------------------------------------
    cart_id = f"cart_{uuid.uuid4().hex}"
    ttl     = int((datetime.utcnow() + timedelta(hours=TTL_HOURS)).timestamp())
    now_iso = datetime.utcnow().isoformat()

    cart_item = {
        "contactId":              cart_id,
        "ttl":                    ttl,
        "recordType":             "CART",
        "cartId":                 cart_id,
        "clientId":               client_id,
        "rawPaymentType":         raw_payment_type,
        "paymentType":            payment_type,           # ◄── Now FULL or PARTIAL
        "paymentAmount":          payment_amount_str,     # ◄── Actual customer amount
        "totalViolationBalance":  total_balance_str,      # ◄── NEW: total owed
        "violationIds":           violation_ids,
        "violationAmounts":       violation_amounts,
        "items":                  items,
        "initialContactId":       initial_contact_id,
        "currentContactId":       current_contact_id,
        "sessionId":              session_id,
        "status":                 "CREATED",
        "createdAt":              now_iso,
        "customerId":             str(body.get("customerId") or "").strip(),
        "accountNumber":          str(body.get("accountNumber") or "").strip(),
    }

    logger.info(
        "Writing cart | table=%s pk(contactId)=%s "
        "rawPaymentType=%s canonicalPaymentType=%s "
        "paymentAmount=%s totalViolationBalance=%s "    # ◄── NEW log field
        "violationIds=%r violationAmounts=%r "
        "initialContactId=%s currentContactId=%s sessionId=%s "
        "items=%d ttl=%s",
        SESSION_TABLE_NAME,
        cart_id,
        raw_payment_type,
        payment_type,
        payment_amount_str,
        total_balance_str,                               # ◄── NEW log field
        violation_ids,
        violation_amounts,
        initial_contact_id,
        current_contact_id,
        session_id,
        len(items),
        ttl,
    )

    # ------------------------------------------------------------------
    # 9. Persist to DynamoDB
    # ------------------------------------------------------------------
    try:
        session_table.put_item(Item=cart_item)
    except ClientError as e:
        logger.exception(
            "PutItem failed | table=%s cartId=%s", SESSION_TABLE_NAME, cart_id
        )
        return _resp(
            500,
            {
                "message": "Failed to persist cart",
                "cartId":  cart_id,
                "error":   str(e),
            },
        )

    logger.info("Cart persisted successfully | cartId=%s", cart_id)

    # ------------------------------------------------------------------
    # 10. Return response
    # ◄── CHANGED: Added totalViolationBalance to response
    # ------------------------------------------------------------------
    return _resp(
        200,
        {
            "cartId":                 cart_id,
            "paymentAmount":          payment_amount_str,
            "totalViolationBalance":  total_balance_str,    # ◄── NEW
            "paymentType":            payment_type,
            "rawPaymentType":         raw_payment_type,
            "violationIds":           violation_ids,
            "violationAmounts":       violation_amounts,
            "items":                  items,
            "initialContactId":       initial_contact_id,
            "currentContactId":       current_contact_id,
            "customerId":             str(body.get("customerId") or "").strip(),
            "accountNumber":          str(body.get("accountNumber") or "").strip(),
        },
    )