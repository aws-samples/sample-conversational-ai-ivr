import json
import boto3
import os
import logging
import uuid
from datetime import datetime
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm_client = boto3.client('ssm')
_gateway_url = None
_api_key = None


def get_payment_config():
    global _gateway_url, _api_key
    if _gateway_url is None:
        try:
            response = ssm_client.get_parameters(
                Names=[
                    os.environ.get('PAYMENT_GATEWAY_URL_PARAM', '/ivr/payment/dev/gateway-url'),
                    os.environ.get('PAYMENT_API_KEY_PARAM', '/ivr/payment/dev/api-key')
                ],
                WithDecryption=True
            )
            params = {p['Name']: p['Value'] for p in response['Parameters']}
            _gateway_url = params.get(os.environ.get('PAYMENT_GATEWAY_URL_PARAM', ''), 'MOCK_MODE')
            _api_key = params.get(os.environ.get('PAYMENT_API_KEY_PARAM', ''), 'MOCK_MODE')
        except Exception as e:
            logger.warning(f"Could not load payment config, defaulting to MOCK_MODE: {e}")
            _gateway_url = 'MOCK_MODE'
            _api_key = 'MOCK_MODE'
    return _gateway_url, _api_key


def lambda_handler(event, context):
    logger.info(f"Payment processing invoked. Intent: {event.get('sessionState', {}).get('intent', {}).get('name', 'unknown')}")
    
    try:
        intent_name = event['sessionState']['intent']['name']
        
        if intent_name == 'CollectPayment':
            return handle_collect_payment(event)
        elif intent_name == 'CancelPayment':
            return handle_cancel_payment(event)
        else:
            return handle_fallback(event)
            
    except Exception as e:
        logger.error(f"Payment processing error: {type(e).__name__}: {str(e)}")
        return build_close_response(event, 'error', '', '', '0', str(e))


def handle_collect_payment(event):
    slots = event['sessionState']['intent']['slots']
    session_attrs = event['sessionState'].get('sessionAttributes', {})
    
    card_number = get_slot_value(slots, 'cardNumber')
    exp_date = get_slot_value(slots, 'expirationDate')
    cvv = get_slot_value(slots, 'cvv')
    billing_zip = get_slot_value(slots, 'billingZip')
    payment_amount = session_attrs.get('paymentAmount', '0')
    account_number = session_attrs.get('accountNumber', '')
    
    if not card_number or not exp_date or not cvv or not billing_zip:
        return build_close_response(
            event, 'validation_error', '', '', payment_amount,
            'Missing card information. Please try again.'
        )
    
    last4 = str(card_number)[-4:] if card_number and len(str(card_number)) >= 4 else '****'
    
    try:
        result = mock_process_payment(str(card_number), payment_amount)
        
        if result['status'] == 'success':
            message = (
                f"Your payment of ${payment_amount} has been processed successfully. "
                f"Your confirmation number is {result['transactionId']}."
            )
            state = 'Fulfilled'
        else:
            message = (
                f"I'm sorry, your payment could not be processed. "
                f"{result.get('errorMessage', 'Please try again.')}"
            )
            state = 'Failed'
            
    except Exception as e:
        logger.error(f"Payment gateway error: {type(e).__name__}")
        result = {'status': 'error', 'transactionId': '', 'errorMessage': 'System error occurred.'}
        message = "We encountered a technical issue. Please try again or speak with an agent."
        state = 'Failed'
    
    return {
        "sessionState": {
            "dialogAction": {"type": "Close"},
            "intent": {"name": "CollectPayment", "state": state},
            "sessionAttributes": {
                'paymentStatus': result['status'],
                'transactionId': result.get('transactionId', ''),
                'last4Digits': last4,
                'paymentAmount': payment_amount,
                'paymentErrorMessage': result.get('errorMessage', ''),
            }
        },
        "messages": [{"contentType": "PlainText", "content": message}]
    }


def handle_cancel_payment(event):
    session_attrs = event['sessionState'].get('sessionAttributes', {})
    return {
        "sessionState": {
            "dialogAction": {"type": "Close"},
            "intent": {"name": "CancelPayment", "state": "Fulfilled"},
            "sessionAttributes": {
                'paymentStatus': 'cancelled',
                'transactionId': '',
                'last4Digits': '',
                'paymentAmount': session_attrs.get('paymentAmount', '0'),
                'paymentErrorMessage': '',
            }
        },
        "messages": [{"contentType": "PlainText", "content": "Payment cancelled. Returning you to our assistant."}]
    }


def handle_fallback(event):
    session_attrs = event['sessionState'].get('sessionAttributes', {})
    return {
        "sessionState": {
            "dialogAction": {"type": "Close"},
            "intent": {"name": event['sessionState']['intent']['name'], "state": "Failed"},
            "sessionAttributes": {
                'paymentStatus': 'error',
                'transactionId': '',
                'last4Digits': '',
                'paymentAmount': session_attrs.get('paymentAmount', '0'),
                'paymentErrorMessage': 'Unable to collect payment information.',
            }
        },
        "messages": [{"contentType": "PlainText", "content": "I was unable to process that. Returning you to our assistant."}]
    }


def mock_process_payment(card_number, amount):
    """
    MOCK PAYMENT PROCESSOR - POC/Demo only
    Card ending in:
      0000 or 1111  -> SUCCESS
      2222          -> DECLINED (insufficient funds)
      3333          -> DECLINED (expired card)
      4444          -> DECLINED (invalid card)
      5555          -> ERROR (gateway timeout)
      6666          -> DECLINED (fraud suspected)
      anything else -> SUCCESS
    """
    clean_card = str(card_number).replace(' ', '').replace('-', '')
    last4 = clean_card[-4:] if len(clean_card) >= 4 else '0000'
    timestamp = datetime.utcnow().strftime('%Y%m%d%H%M%S')
    
    time.sleep(1.5)
    
    scenarios = {
        '2222': {'status': 'declined', 'transactionId': '', 'errorMessage': 'Your card was declined due to insufficient funds.'},
        '3333': {'status': 'declined', 'transactionId': '', 'errorMessage': 'Your card appears to be expired.'},
        '4444': {'status': 'declined', 'transactionId': '', 'errorMessage': 'The card number is invalid.'},
        '5555': {'status': 'error', 'transactionId': '', 'errorMessage': 'Payment system temporarily unavailable.'},
        '6666': {'status': 'declined', 'transactionId': '', 'errorMessage': 'Transaction flagged for security review.'},
    }
    
    if last4 in scenarios:
        logger.info(f"MOCK: Payment {scenarios[last4]['status'].upper()} for ${amount} (card ending {last4})")
        return scenarios[last4]
    
    txn_id = f"TXN-{timestamp}-{uuid.uuid4().hex[:8].upper()}"
    logger.info(f"MOCK: Payment SUCCESS for ${amount}, txn: {txn_id}")
    return {'status': 'success', 'transactionId': txn_id, 'errorMessage': ''}


def build_close_response(event, status, txn_id, last4, amount, error_msg):
    return {
        "sessionState": {
            "dialogAction": {"type": "Close"},
            "intent": {"name": event['sessionState']['intent']['name'], "state": "Failed"},
            "sessionAttributes": {
                'paymentStatus': status,
                'transactionId': txn_id,
                'last4Digits': last4,
                'paymentAmount': amount,
                'paymentErrorMessage': error_msg,
            }
        },
        "messages": [{"contentType": "PlainText", "content": f"Payment issue: {error_msg}"}]
    }


def get_slot_value(slots, slot_name):
    if not slots or slot_name not in slots or slots[slot_name] is None:
        return None
    slot = slots[slot_name]
    if 'value' in slot and slot['value']:
        return slot['value'].get('interpretedValue', None)
    return None
