# anycompany-ivr-dev-QinConnectDialogHook
# Version: 3.3 — Added session attribute fallback for payment detection
#
# CHANGE LOG v3.3:
#   - Added fallback detection: Tool=Escalate + escalationReason=PAYMENT_TRANSFER
#   - Fixes env where x-amz-lex:q-in-connect-response is "..." instead of full text
#   - Text-based detection remains primary method (unchanged)
#   - All other logic unchanged from v3.2
#
# Cart record field map (confirmed):
#   PK:              contactId = "cart_"
#   cartId:          cartId    = "cart_"   (duplicate of PK)
#   sessionId:       sessionId = ""
#   initialContactId:initialContactId = ""  (== sessionId)
#   paymentAmount:   paymentAmount = "275.00"   (string, no totalAmount field)
#   violationIds:    violationIds  = "viol_024_04"
#   violationAmounts:violationAmounts = "275.00"
#   paymentType:     paymentType   = "SPECIFIC"
#   rawPaymentType:  rawPaymentType = "PARTIAL_VIOLATION_SELECTION"
#   clientId:        clientId = "CLIENT_001"
#   recordType:      recordType = "CART"
#   status:          status = "CREATED"
#   NOTE: customerId and accountNumber NOT present in cart — omitted
import json
import re
import os
import boto3
import logging
from boto3.dynamodb.conditions import Key, Attr
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("SESSION_TABLE_NAME", "IVRSessionContext-dev")
dynamodb   = boto3.resource("dynamodb", region_name="us-east-1")
table      = dynamodb.Table(TABLE_NAME)

PAYMENT_TRIGGER_PHRASES = [
    "secure payment system",
    "transferring you to",
    "transfer you to",
    "connecting you to",
    "payment system now",
    "collect your payment",
    "process your payment",
]

BAD_UUIDS = {
    "b1b0ff7d-4d6a-424e-980e-883770eb9061",
    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "",
    "none",
    "null",
    "undefined",
}


def _normalize_text(text):
    if not text:
        return ""
    text = text.replace("\u2019", "'").replace("\u2018", "'")
    text = text.replace("\u201c", '"').replace("\u201d", '"')
    text = re.sub(r"\s+", " ", text)
    return text.lower().strip()


def _detect_payment_phrase(normalized_text):
    for phrase in PAYMENT_TRIGGER_PHRASES:
        if phrase in normalized_text:
            return phrase
    return None


def _is_bad_id(value):
    return not value or value.strip().lower() in BAD_UUIDS


def _get_cart_for_session(session_id):
    if _is_bad_id(session_id):
        logger.warning("Bad session_id='%s' - skipping lookup", session_id)
        return None

    logger.info("Cart lookup | session_id=%s", session_id)

    cart = _query_gsi_initial_contact(session_id)
    if cart:
        return cart

    return _scan_for_cart(session_id)


def _query_gsi_initial_contact(session_id):
    try:
        resp = table.query(
            IndexName="initialContactId-index",
            KeyConditionExpression=(
                Key("initialContactId").eq(session_id) &
                Key("recordType").eq("CART")
            ),
        )
        items = resp.get("Items", [])
        if not items:
            logger.info("GSI query returned 0 items")
            return None

        items.sort(key=lambda x: x.get("createdAt", ""), reverse=True)
        logger.info("Cart via GSI | cartId=%s", items[0].get("cartId"))
        return items[0]

    except Exception as e:
        err = str(e)
        if "index" in err.lower() or "ResourceNotFoundException" in err:
            logger.info("initialContactId-index not yet active - will scan")
        else:
            logger.warning("GSI query error: %s", err)
        return None


def _scan_for_cart(session_id):
    try:
        filter_expr = (
            Attr("contactId").begins_with("cart_") &
            Attr("recordType").eq("CART") &
            (
                Attr("initialContactId").eq(session_id) |
                Attr("sessionId").eq(session_id)
            )
        )

        items = []
        scan_kw = {"FilterExpression": filter_expr}
        page_num = 0

        while True:
            page_num += 1
            resp = table.scan(**scan_kw)
            batch = resp.get("Items", [])
            items.extend(batch)
            logger.info("Scan page %d: %d matches | scanned=%d",
                        page_num, len(batch), resp.get("ScannedCount", 0))

            if "LastEvaluatedKey" not in resp:
                break
            scan_kw["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

        logger.info("Scan total: %d cart(s) found", len(items))

        if not items:
            logger.error("No cart found for session_id=%s", session_id)
            return None

        items.sort(key=lambda x: x.get("createdAt", ""), reverse=True)
        logger.info("Cart via scan | cartId=%s", items[0].get("cartId"))
        return items[0]

    except Exception as e:
        logger.error("Scan error: %s", e)
        return None


def _cart_to_session_attrs(cart):
    def _s(val):
        if val is None:
            return ""
        if isinstance(val, (list, dict)):
            return json.dumps(val)
        return str(val)

    cart_id = _s(cart.get("cartId") or cart.get("contactId") or "")

    attrs = {
        "cartId":           cart_id,
        "paymentAmount":    _s(cart.get("paymentAmount", "")),
        "violationIds":     _s(cart.get("violationIds", "")),
        "violationAmounts": _s(cart.get("violationAmounts", "")),
        "paymentType":      _s(cart.get("paymentType", "")),
        "rawPaymentType":   _s(cart.get("rawPaymentType", "")),
        "clientId":         _s(cart.get("clientId", "")),
        "cartSessionId":    _s(cart.get("sessionId", "")),
        "customerId":       _s(cart.get("customerId", "")),
        "accountNumber":    _s(cart.get("accountNumber", "")),
        "Tool":             "initiatePayment",
        "routeToPayment":   "true",
    }

    logger.info(
        "Cart->SessionAttrs | cartId=%s | amount=%s | violationIds=%s",
        attrs["cartId"], attrs["paymentAmount"], attrs["violationIds"]
    )
    return attrs


def lambda_handler(event, context):
    logger.info("EVENT: %s", json.dumps(event))

    invocation_source = event.get("invocationSource", "")
    session_state = event.get("sessionState", {})
    session_attrs = dict(session_state.get("sessionAttributes", {}) or {})
    request_attrs = event.get("requestAttributes", {}) or {}
    input_transcript = event.get("inputTranscript", "").strip()

    intent_name = session_state.get("intent", {}).get("name", "AmazonQinConnect")

    logger.info("invocationSource=%s | intent=%s | transcript='%s'",
                invocation_source, intent_name, input_transcript[:100])

    # =================================================================
    # DialogCodeHook: Return None to let Lex/Q in Connect handle natively
    #
    # CRITICAL: For AmazonQinConnect intents, the DialogCodeHook fires
    # BEFORE Nova Sonic/Q in Connect processes the turn. Returning ANY
    # response (even Delegate) interferes with Nova Sonic's session
    # management, especially the SessionStart event on the first turn.
    #
    # By returning None, Lex treats it as if no hook was configured
    # and proceeds normally with Q in Connect orchestration.
    # =================================================================
    if invocation_source == "DialogCodeHook":
        logger.info("DialogCodeHook - returning None to let Q in Connect handle natively")
        return None

    # =================================================================
    # FulfillmentCodeHook: This is where Q in Connect response IS available
    # Check for payment trigger phrases and route accordingly
    # =================================================================
    if invocation_source == "FulfillmentCodeHook":
        logger.info("FulfillmentCodeHook - checking for payment triggers")

        # Resolve session_id
        session_id = (
            session_attrs.get("sessionId")
            or session_attrs.get("initialContactId")
            or request_attrs.get("sessionId")
            or request_attrs.get("initialContactId")
            or event.get("sessionId", "")
        ).strip()

        logger.info("Resolved session_id='%s'", session_id)

        # Post-payment resume
        if session_attrs.get("resumeAfterPayment") == "true":
            logger.info("resumeAfterPayment=true - clearing payment signals")
            for key in [
                "Tool", "routeToPayment",
                "cartId", "paymentAmount", "violationIds", "violationAmounts",
                "paymentType", "rawPaymentType", "clientId", "cartSessionId",
                "hookClosedAt", "detectedPhrase", "cartLookupStatus",
            ]:
                session_attrs.pop(key, None)
            session_attrs["resumeAfterPayment"] = "cleared"
            # Let fulfillment proceed normally
            return None

        # Read Nova Sonic response - at FulfillmentCodeHook it should be available
        nova_raw = (
            session_attrs.get("x-amz-lex:q-in-connect-response", "")
            or request_attrs.get("x-amz-lex:q-in-connect-response", "")
        )
        nova_norm = _normalize_text(nova_raw)

        logger.info("Nova raw  [%d chars]: '%s'", len(nova_raw), nova_raw[:300])
        logger.info("Nova norm [%d chars]: '%s'", len(nova_norm), nova_norm[:300])

        # Payment phrase detection — Method 1: AI response text (primary)
        matched_phrase = _detect_payment_phrase(nova_norm)

        # ─── BEGIN v3.3 CHANGE ───────────────────────────────────
        # Method 2: Session attribute signals (fallback)
        # Needed when x-amz-lex:q-in-connect-response is "..." instead
        # of the full AI response text. The Escalate tool with
        # PAYMENT_TRANSFER reason is the structured equivalent of the
        # AI saying "I'll transfer you to our secure payment system."
        if not matched_phrase:
            tool = session_attrs.get("Tool", "").strip()
            esc_reason = session_attrs.get("escalationReason", "").strip()
            if tool == "Escalate" and esc_reason == "PAYMENT_TRANSFER":
                matched_phrase = "session_attr:PAYMENT_TRANSFER"
                logger.info("PAYMENT_TRANSFER detected via session attrs (Tool=%s, escalationReason=%s)", tool, esc_reason)

        if not matched_phrase:
            logger.info("No payment trigger at fulfillment - returning None")
            return None
        # ─── END v3.3 CHANGE ─────────────────────────────────────

        # Payment transfer detected
        logger.info("PAYMENT PHRASE DETECTED: '%s'", matched_phrase)

        cart = _get_cart_for_session(session_id)

        if cart:
            session_attrs.update(_cart_to_session_attrs(cart))
            session_attrs["cartLookupStatus"] = "found"
            logger.info("Cart data merged into session attrs")
        else:
            logger.error("Cart NOT found for session_id='%s'", session_id)
            session_attrs["Tool"]             = "initiatePayment"
            session_attrs["routeToPayment"]   = "true"
            session_attrs["cartId"]           = ""
            session_attrs["paymentAmount"]    = ""
            session_attrs["violationIds"]     = ""
            session_attrs["violationAmounts"] = ""
            session_attrs["cartLookupStatus"] = "not_found"

        session_attrs["hookClosedAt"]   = datetime.now(timezone.utc).isoformat()
        session_attrs["detectedPhrase"] = matched_phrase

        # Return Close with payment routing signals
        logger.info(
            "CLOSING SESSION | cartId=%s | amount=%s | Tool=%s",
            session_attrs.get("cartId", "EMPTY"),
            session_attrs.get("paymentAmount", "EMPTY"),
            session_attrs.get("Tool", "EMPTY")
        )
        return {
            "sessionState": {
                "dialogAction": {"type": "Close"},
                "sessionAttributes": session_attrs,
                "intent": {
                    "name": intent_name,
                    "state": "Fulfilled"
                }
            }
        }

    # Unknown invocation source - don't interfere
    logger.info("Unknown invocationSource='%s' - returning None", invocation_source)
    return None
