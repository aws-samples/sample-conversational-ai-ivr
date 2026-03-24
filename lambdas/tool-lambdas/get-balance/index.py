# lambda_functions/get_balance/index.py
"""
Tool: getBalance
Description: Get account balance summary for a customer.
             Returns total amount due, violation count, and payment eligibility.

Input Parameters:
  - customerId (required): Unique customer identifier
  - clientId (required): Client identifier for data isolation

Output:
  - Balance summary including totalBalance, violationCount, accountStatus
"""

import json
import boto3
import os
import logging
from decimal import Decimal
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
CUSTOMERS_TABLE = os.environ.get('CUSTOMERS_TABLE')
VIOLATIONS_TABLE = os.environ.get('VIOLATIONS_TABLE')

customers_table = dynamodb.Table(CUSTOMERS_TABLE)
violations_table = dynamodb.Table(VIOLATIONS_TABLE)


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def lambda_handler(event, context):
    """Main handler for getBalance tool."""
    logger.info(f"getBalance invoked with event: {json.dumps(event)}")
    
    params, source = parse_event(event)
    
    required_fields = ['customerId', 'clientId']
    validation_error = validate_required_fields(params, required_fields)
    if validation_error:
        return format_error(validation_error, 'MISSING_PARAMETERS', source)
    
    customer_id = params['customerId']
    client_id = params['clientId']
    
    try:
        # Get customer
        customer_response = customers_table.get_item(
            Key={
                'PK': f"CLIENT#{client_id}#CUST#{customer_id}",
                'SK': 'PROFILE'
            }
        )
        
        customer = customer_response.get('Item')
        if not customer:
            return format_error('Customer not found', 'CUSTOMER_NOT_FOUND', source, 404)
        
        # Get violations
        response = violations_table.query(
            IndexName='GSI2-Customer-Index',
            KeyConditionExpression=Key('GSI2PK').eq(f"CLIENT#{client_id}#CUST#{customer_id}")
        )
        
        violations = response.get('Items', [])
        open_violations = [v for v in violations if v.get('status') in ['OPEN', 'PARTIAL']]
        payable_violations = [v for v in open_violations if v.get('isPayable', True)]
        
        total_balance = sum(Decimal(str(v.get('amount', 0))) for v in open_violations)
        payable_balance = sum(Decimal(str(v.get('amount', 0))) for v in payable_violations)
        
        # Get oldest violation date
        oldest_date = None
        dates = [v.get('violationDate') for v in open_violations if v.get('violationDate')]
        if dates:
            oldest_date = min(dates)
        
        balance_msg = f"Your current balance is ${float(total_balance):.2f}"
        if len(open_violations) > 0:
            balance_msg += f" for {len(open_violations)} violation(s)"
        
        result = {
            'success': True,
            'customerId': customer_id,
            'customerName': customer.get('customerName', ''),
            'totalBalance': float(total_balance),
            'totalPayableBalance': float(payable_balance),
            'violationCount': len(open_violations),
            'payableViolationCount': len(payable_violations),
            'oldestViolationDate': oldest_date,
            'accountStatus': customer.get('accountStatus', 'ACTIVE'),
            'hasPaymentPlan': customer.get('hasPaymentPlan', False),
            'lastPaymentDate': customer.get('lastPaymentDate'),
            'lastPaymentAmount': float(customer.get('lastPaymentAmount', 0)) if customer.get('lastPaymentAmount') else None,
            'message': balance_msg
        }
        
        return format_response(result, source, 'getBalance')
        
    except Exception as e:
        logger.error(f"Error: {str(e)}", exc_info=True)
        return format_error(str(e), 'INTERNAL_ERROR', source, 500)


def parse_event(event):
    if 'actionGroup' in event or 'function' in event:
        return {p['name']: p['value'] for p in event.get('parameters', [])}, 'bedrock'
    if 'body' in event:
        try:
            return json.loads(event.get('body', '{}')), 'apigateway'
        except:
            return {}, 'apigateway'
    return event, 'direct'


def validate_required_fields(params, fields):
    missing = [f for f in fields if not params.get(f)]
    return f"Missing: {', '.join(missing)}" if missing else None


def format_response(data, source, func):
    if source == 'bedrock':
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': 'BalanceServices',
                'function': func,
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data, cls=DecimalEncoder)}}}
            }
        }
    return {
        'statusCode': 200,
        'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
        'body': json.dumps(data, cls=DecimalEncoder)
    }


def format_error(msg, code, source, status=400):
    data = {'success': False, 'error': msg, 'code': code}
    if source == 'bedrock':
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': 'BalanceServices',
                'function': 'getBalance',
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data)}}}
            }
        }
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(data)}