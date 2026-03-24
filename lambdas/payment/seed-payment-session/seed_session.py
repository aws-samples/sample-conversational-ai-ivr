import boto3
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

PAYMENT_BOT_ID = os.environ["PAYMENT_BOT_ID"]
PAYMENT_BOT_ALIAS_ID = os.environ["PAYMENT_BOT_ALIAS_ID"]

def lambda_handler(event, context):
    logger.info("Seed session started")
    try:
        contact_data = event.get("Details", {}).get("ContactData", {})
        attrs = contact_data.get("Attributes", {})
        contact_id = contact_data.get("ContactId", "")
        initial_contact_id = contact_data.get("InitialContactId",
                             attrs.get("initialContactId", ""))
        payment_amount = attrs.get("paymentAmount", "0")
        payment_cart_id = attrs.get("paymentCartId", "")
        customer_id = attrs.get("customerId", "")
        account_number = attrs.get("accountNumber", "")
        client_id = attrs.get("clientId", "")

        logger.info("contact_id=" + contact_id + ", amount=" + payment_amount)

        lex = boto3.client("lexv2-runtime", region_name="us-east-1")

        lex.put_session(
            botId=PAYMENT_BOT_ID,
            botAliasId=PAYMENT_BOT_ALIAS_ID,
            localeId="en_US",
            sessionId=contact_id,
            sessionState={
                "sessionAttributes": {
                    "paymentAmount": str(payment_amount),
                    "paymentCartId": str(payment_cart_id),
                    "customerId": str(customer_id),
                    "accountNumber": str(account_number),
                    "clientId": str(client_id),
                    "initialContactId": str(initial_contact_id),
                    "sessionId": str(initial_contact_id)
                },
                "dialogAction": {
                    "type": "ElicitSlot",
                    "slotToElicit": "cardNumber"
                },
                "intent": {
                    "name": "CollectPayment",
                    "slots": {},
                    "state": "InProgress"
                }
            },
            messages=[
                {
                    "contentType": "PlainText",
                    "content": "Please provide your 16-digit credit or debit card number."
                }
            ],
            responseContentType="text/plain; charset=utf-8"
        )

        logger.info("PutSession SUCCESS")
        return {"sessionSeeded": "true", "contactId": str(contact_id)}

    except Exception as e:
        logger.error("FAILED: " + type(e).__name__ + ": " + str(e))
        return {"sessionSeeded": "false", "error": str(type(e).__name__)}