"""
initiate_payment.py (FIXED)

Root cause of 502: Lambda was behind API Gateway proxy but returning
a plain dict instead of the required API Gateway response envelope
{statusCode, headers, body}. API Gateway cannot interpret a plain
dict response and returns 502 Bad Gateway to the caller (AgentCore).

Additional fix: violationIds was being read from the incoming request
params instead of from the cart items stored in DynamoDB, causing it
to always be empty.

Response shape required by API Gateway proxy integration:
{
    "statusCode": <int>,
    "headers":    {"Content-Type": "application/json"},
    "body":       ""
}

The body content (parsed by AgentCore) must match the OpenAPI schema:
{
    "success":           true,
    "shouldTransfer":    true,
    "sessionAttributes": { ... string key/value pairs ... },
    "message":           "..."
}

Env vars:
- SESSION_TABLE_NAME (required)
- LOG_LEVEL (optional)

IAM:
- dynamodb:GetItem on SESSION_TABLE_NAME
"""

import json
import os
import logging
from typing import Any, Dict

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))

dynamodb           = boto3.resource("dynamodb")
SESSION_TABLE_NAME = os.environ["SESSION_TABLE_NAME"]
session_table      = dynamodb.Table(SESSION_TABLE_NAME)


# ---------------------------------------------------------------------------
# Response helpers — ALWAYS return API Gateway proxy format
# ---------------------------------------------------------------------------

def _resp(status_code: int, body: dict) -> dict:
    """
    Wrap response in API Gateway proxy format.
    This is required because the Lambda sits behind API Gateway.
    Without this wrapper API Gateway returns 502 Bad Gateway.
    """
    return {
        "statusCode": status_code,
        "headers":    {"Content-Type": "application/json"},
        "body":       json.dumps(body, default=str),
    }


def _error_resp(status_code: int, message: str) -> dict:
    """
    Return a structured error in API Gateway proxy format.
    """
    logger.error("initiatePayment error | status=%d message=%s", status_code, message)
    return _resp(status_code, {
        "success":        False,
        "shouldTransfer": False,
        "message":        message,
    })


# ---------------------------------------------------------------------------
# Event parser — handles all invocation formats
# ---------------------------------------------------------------------------

def _parse_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Handle all invocation formats:
    1. AgentCore tool invocation - parameters as list of {name, value}
    2. AgentCore tool invocation - parameters as dict
    3. API Gateway proxy event   - body as JSON string  ← primary path
    4. Direct Lambda invocation  - plain dict
    """
    logger.info("Raw event: %s", json.dumps(event, default=str))

    # ── AgentCore format: {"parameters": [{"name":"cartId","value":"cart_xxx"}]}
    if "parameters" in event:
        params = event["parameters"]
        if isinstance(params, list):
            parsed = {p["name"]: p["value"] for p in params
                      if isinstance(p, dict) and "name" in p}
            logger.info("AgentCore list params: %s", parsed)
            return parsed
        if isinstance(params, dict):
            logger.info("AgentCore dict params: %s", params)
            return params

    # ── API Gateway proxy event (primary invocation path)
    if "body" in event:
        raw = event.get("body") or ""
        if event.get("isBase64Encoded"):
            import base64
            raw = base64.b64decode(raw).decode("utf-8")
        if isinstance(raw, str) and raw.strip():
            parsed = json.loads(raw)
            logger.info("API GW body params: %s", parsed)
            return parsed
        if isinstance(raw, dict):
            return raw
        return {}

    # ── Direct Lambda invocation
    logger.info("Direct invocation params: %s", event)
    return event if isinstance(event, dict) else {}


# ---------------------------------------------------------------------------
# violationIds / violationAmounts normalizer (same pattern as buildPaymentCart)
# ---------------------------------------------------------------------------

def _to_csv_string(value) -> str:
    """
    Normalize violationIds or violationAmounts to a clean CSV string.
    Accepts: list, CSV string, single value, None.
    """
    if value is None:
        return ""
    if isinstance(value, list):
        return ",".join(str(v).strip() for v in value if str(v).strip())
    if isinstance(value, str):
        return ",".join(v.strip() for v in value.split(",") if v.strip())
    return str(value).strip()


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event: Dict[str, Any], context: Any) -> dict:

    req_id = getattr(context, "aws_request_id", "unknown")
    logger.info(
        "initiatePayment invoked | requestId=%s table=%s",
        req_id, SESSION_TABLE_NAME,
    )

    # ------------------------------------------------------------------
    # 1. Parse incoming parameters
    # ------------------------------------------------------------------
    try:
        params = _parse_event(event)
    except Exception as e:
        logger.exception("Failed to parse event")
        return _error_resp(400, f"Invalid request format: {str(e)}")

    cart_id = str(params.get("cartId") or "").strip()
    logger.info("Parsed params | cartId=%s", cart_id)

    # ------------------------------------------------------------------
    # 2. Validate required fields
    # ------------------------------------------------------------------
    if not cart_id:
        logger.error("Missing cartId in params: %s", params)
        return _error_resp(400, "Missing cartId. Please provide a valid cart ID.")

    user_confirmed = params.get("userConfirmed")
    # Accept both boolean True and string "true"
    if isinstance(user_confirmed, str):
        user_confirmed = user_confirmed.strip().lower() == "true"
    if not user_confirmed:
        logger.warning("userConfirmed is not true | cartId=%s value=%s",
                       cart_id, params.get("userConfirmed"))
        return _error_resp(400, "Payment requires explicit customer confirmation.")

    # ------------------------------------------------------------------
    # 3. Fetch cart from DynamoDB
    #    Cart was written by buildPaymentCart with PK contactId = cartId
    # ------------------------------------------------------------------
    try:
        response = session_table.get_item(
            Key={"contactId": cart_id},
            ConsistentRead=True,
        )
        cart = response.get("Item")
    except ClientError as e:
        logger.exception("DynamoDB GetItem failed | cartId=%s", cart_id)
        return _error_resp(500, f"Failed to retrieve payment cart: {str(e)}")

    # ------------------------------------------------------------------
    # 4. Guard: cart not found or expired
    # ------------------------------------------------------------------
    if not cart:
        logger.warning("Cart not found | cartId=%s", cart_id)
        return _error_resp(404,
            f"Payment cart {cart_id} not found or has expired. "
            f"Please start the payment process again."
        )

    # ------------------------------------------------------------------
    # 5. Extract cart details
    #    Read violationIds from cart.items — NOT from incoming params.
    #    The AI agent does not re-send violationIds to initiatePayment;
    #    they were stored in the cart by buildPaymentCart.
    # ------------------------------------------------------------------
    payment_amount     = str(cart.get("paymentAmount",    ""))
    client_id          = str(cart.get("clientId",         ""))
    payment_type       = str(cart.get("paymentType",      ""))
    raw_payment_type   = str(cart.get("rawPaymentType",   payment_type))
    initial_contact_id = str(cart.get("initialContactId", ""))
    cart_status        = str(cart.get("status",           ""))
    items              = cart.get("items", [])

    # Prefer pre-built CSV strings stored by buildPaymentCart (new format).
    # Fall back to building from items list (legacy carts).
    if cart.get("violationIds"):
        violation_ids     = _to_csv_string(cart["violationIds"])
        violation_amounts = _to_csv_string(cart.get("violationAmounts", ""))
    else:
        # Legacy cart — build CSV from items list
        violation_ids     = _to_csv_string(
            [str(i.get("violationId", "")) for i in items]
        )
        violation_amounts = _to_csv_string(
            [str(i.get("amount", ""))      for i in items]
        )

    violation_count = len(items) if items else len(
        [v for v in violation_ids.split(",") if v]
    )

    # Optional fields from the request (pass-through for downstream context)
    customer_id          = str(params.get("customerId")         or cart.get("customerId",         ""))
    account_number       = str(params.get("accountNumber")      or cart.get("accountNumber",       ""))
    payment_reason       = str(params.get("paymentReason")      or cart.get("paymentReason",       "VIOLATION_PAYMENT"))
    customer_name        = str(params.get("customerName")       or cart.get("customerName",        ""))
    conversation_summary = str(params.get("conversationSummary") or "")
    session_id           = str(params.get("sessionId")          or initial_contact_id)

    logger.info(
        "Cart found | cartId=%s amount=%s violations=%d "
        "clientId=%s status=%s initialContactId=%s "
        "violationIds=%r violationAmounts=%r "
        "rawPaymentType=%s canonicalPaymentType=%s",
        cart_id, payment_amount, violation_count,
        client_id, cart_status, initial_contact_id,
        violation_ids, violation_amounts,
        raw_payment_type, payment_type,
    )

    # ------------------------------------------------------------------
    # 6. Build response
    #
    #    CRITICAL: Must be wrapped in API Gateway proxy format.
    #    The body must match the OpenAPI schema for initiatePayment:
    #    {
    #        success:           bool
    #        shouldTransfer:    bool
    #        sessionAttributes: object (string key/value pairs)
    #        message:           string
    #    }
    #
    #    sessionAttributes values are ALL strings — Connect contact
    #    attributes and Lex session attributes are string-only.
    #    The Connect flow reads these from $.Lex.SessionAttributes.*
    # ------------------------------------------------------------------
    session_attributes = {
        # ── Routing signal — Connect flow checks $.Lex.SessionAttributes.Tool
        "Tool":               "initiatePayment",
        "routeToPayment":     "true",

        # ── Payment identifiers
        "cartId":             cart_id,
        "paymentAmount":      payment_amount,
        "paymentType":        payment_type,        # canonical (ALL_PAYABLE / SPECIFIC)
        "rawPaymentType":     raw_payment_type,    # original value sent by AI agent

        # ── Violation details — needed by UpdateViolationBalance Lambda
        "violationIds":       violation_ids,       # CSV string
        "violationAmounts":   violation_amounts,   # CSV string

        # ── Customer / account context
        "customerId":         customer_id,
        "accountNumber":      account_number,
        "clientId":           client_id,
        "customerName":       customer_name,

        # ── Payment metadata
        "paymentReason":      payment_reason,
        "conversationSummary": conversation_summary,
        "lastIntent":         "initiatePayment",

        # ── Session continuity — used by SaveAndRestoreSession Lambda
        "sessionId":          session_id,
        "initialContactId":   initial_contact_id,
    }

    body = {
        # ── Required by OpenAPI schema
        "success":           True,
        "shouldTransfer":    True,
        "sessionAttributes": session_attributes,

        # ── ADD THESE TOP LEVEL FIELDS ─────────────────────────
        # Model reads these directly without needing to navigate
        # into the nested sessionAttributes object
        "Tool":              "initiatePayment",
        "routeToPayment":    "true",
        "cartId":            cart_id,
        "paymentAmount":     payment_amount,
        "transferReady":     True,
        "message": (
            f"Payment cart confirmed and transfer ready. "
            f"Amount: ${payment_amount} for "
            f"{violation_count} violation(s). "
            f"Tool has been set to initiatePayment. "
            f"routeToPayment has been set to true. "
            f"Session attributes have been propagated. "
            f"Transfer to secure payment system is now active."
        ),
    }

    logger.info(
        "initiatePayment response | cartId=%s amount=%s "
        "violationIds=%r routeToPayment=true",
        cart_id, payment_amount, violation_ids,
    )

    # ------------------------------------------------------------------
    # 7. Return with API Gateway proxy wrapper
    #    This resolves the 502. API Gateway requires statusCode in the
    #    Lambda response to construct the HTTP response correctly.
    # ------------------------------------------------------------------
    return _resp(200, body)