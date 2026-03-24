# lambda_functions/lookup_by_account/index.py
"""
Tool: lookupByAccount
Description: Look up customer account by account number and zip code.
             Primary identification method for collections clients.

Input Parameters:
  - accountNumber (required): Customer account number
  - zipCode (required): Customer's billing zip code
  - clientId (required): Client identifier for data isolation

Output:
  - Customer identification details including customerId, name, balance, and violation count
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
    """Main handler for lookupByAccount tool."""
    logger.info(f"lookupByAccount invoked with event: {json.dumps(event)}")
    
    params, source = parse_event(event)
    
    required_fields = ['accountNumber', 'zipCode', 'clientId']
    validation_error = validate_required_fields(params, required_fields)
    if validation_error:
        return format_error(validation_error, 'MISSING_PARAMETERS', source)
    
    account_number = params['accountNumber'].upper().strip()
    zip_code = params['zipCode'].strip()
    client_id = params['clientId']
    
    try:
        # Query GSI2 for account lookup
        gsi2pk = f"CLIENT#{client_id}#ACCT#{account_number}"
        gsi2sk = f"ZIP#{zip_code}"
        
        response = customers_table.query(
            IndexName='GSI2-AccountNumber-Index',
            KeyConditionExpression=Key('GSI2PK').eq(gsi2pk) & Key('GSI2SK').eq(gsi2sk)
        )
        
        if not response.get('Items'):
            # Try just account number
            response = customers_table.query(
                IndexName='GSI2-AccountNumber-Index',
                KeyConditionExpression=Key('GSI2PK').eq(gsi2pk)
            )
            
            if not response.get('Items'):
                result = {
                    'success': True,
                    'accountFound': False,
                    'message': 'No account found with the provided account number',
                    'suggestions': [
                        'Verify the account number is correct',
                        'Ensure the zip code matches your billing address',
                        'Contact customer service for assistance'
                    ]
                }
                return format_response(result, source, 'lookupByAccount')
            
            # Account found but zip mismatch
            result = {
                'success': True,
                'accountFound': False,
                'message': 'Unable to verify account with provided zip code',
                'suggestions': [
                    'Ensure the zip code matches your billing address',
                    'Contact customer service for assistance'
                ]
            }
            return format_response(result, source, 'lookupByAccount')
        
        customer = response['Items'][0]
        customer_id = customer['customerId']
        
        violation_summary = get_violation_summary(client_id, customer_id)
        
        requires_agent = (
            customer.get('accountStatus') in ['SUSPENDED', 'COLLECTIONS'] or
            violation_summary['count'] > 10
        )
        
        result = {
            'success': True,
            'accountFound': True,
            'customerId': customer_id,
            'customerName': customer.get('customerName', ''),
            'totalBalance': violation_summary['totalBalance'],
            'violationCount': violation_summary['count'],
            'accountStatus': customer.get('accountStatus', 'ACTIVE'),
            'isPayable': violation_summary['isPayable'] and not requires_agent,
            'requiresAgentAssistance': requires_agent,
            'message': f"Account found with {violation_summary['count']} outstanding violation(s)"
        }
        
        return format_response(result, source, 'lookupByAccount')
        
    except Exception as e:
        logger.error(f"Error: {str(e)}", exc_info=True)
        return format_error(str(e), 'INTERNAL_ERROR', source, 500)


def get_violation_summary(client_id, customer_id):
    try:
        response = violations_table.query(
            IndexName='GSI2-Customer-Index',
            KeyConditionExpression=Key('GSI2PK').eq(f"CLIENT#{client_id}#CUST#{customer_id}")
        )
        violations = response.get('Items', [])
        open_v = [v for v in violations if v.get('status') in ['OPEN', 'PARTIAL']]
        total = sum(Decimal(str(v.get('amount', 0))) for v in open_v)
        return {'count': len(open_v), 'totalBalance': float(total), 'isPayable': len(open_v) > 0}
    except:
        return {'count': 0, 'totalBalance': 0.0, 'isPayable': False}


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
                'actionGroup': 'AccountLookup',
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
                'actionGroup': 'AccountLookup',
                'function': 'lookupByAccount',
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data)}}}
            }
        }
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(data)}