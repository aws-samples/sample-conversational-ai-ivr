# lambda_functions/lookup_by_plate/index.py
"""
Tool: lookupByPlate
Description: Look up customer account by license plate number and state.
             Used for servicing clients to identify customers with parking violations.

Input Parameters:
  - licensePlate (required): Vehicle license plate number
  - state (required): US state code (e.g., FL, CA, NY)
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

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize DynamoDB
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
    """
    Main handler for lookupByPlate tool.
    Supports invocation from: API Gateway, Bedrock Agent, Direct
    """
    logger.info(f"lookupByPlate invoked with event: {json.dumps(event)}")
    
    # DEBUG: Log raw event first
    logger.info("=" * 50)
    logger.info("DEBUG: RAW EVENT START")
    logger.info(f"Event type: {type(event)}")
    logger.info(f"Raw event: {json.dumps(event)}")
    logger.info("DEBUG: RAW EVENT END")
    logger.info("=" * 50)

    # Check if body contains INVALID
    if 'body' in event:
        logger.info(f"DEBUG: Raw body value: {event.get('body')}")
    
    # Parse event based on source
    params, source = parse_event(event)
    logger.info(f"Source: {source}, Params: {params}")

    # Parse event based on source
    params, source = parse_event(event)
    logger.info(f"Source: {source}, Params: {params}")
    
    # Validate required fields
    required_fields = ['licensePlate', 'state', 'clientId']
    validation_error = validate_required_fields(params, required_fields)
    if validation_error:
        return format_error(validation_error, 'MISSING_PARAMETERS', source)
    
    # Extract parameters
    license_plate = params['licensePlate'].upper().strip()
    state = params['state'].upper().strip()
    client_id = params['clientId']
    
    try:
        # Query GSI1 for license plate lookup
        gsi1pk = f"CLIENT#{client_id}#PLATE#{license_plate}#{state}"
        
        response = customers_table.query(
            IndexName='GSI1-LicensePlate-Index',
            KeyConditionExpression=Key('GSI1PK').eq(gsi1pk)
        )
        
        if not response.get('Items'):
            result = {
                'success': True,
                'accountFound': False,
                'message': 'No account found with the provided license plate and state',
                'suggestions': [
                    'Verify the license plate number is correct',
                    'Ensure the state code matches your vehicle registration',
                    'Try using your citation number instead'
                ]
            }
            return format_response(result, source, 'lookupByPlate')
        
        customer = response['Items'][0]
        customer_id = customer['customerId']
        
        # Get violation summary
        violation_summary = get_violation_summary(client_id, customer_id)
        
        # Determine if requires agent
        requires_agent = (
            customer.get('accountStatus') in ['SUSPENDED', 'COLLECTIONS'] or
            violation_summary['count'] > 10
        )
        
        result = {
            'success': True,
            'accountFound': True,
            'customerId': customer_id,
            'customerName': customer.get('customerName', ''),
            'accountNumber': customer.get('accountNumber', ''),
            'totalBalance': violation_summary['totalBalance'],
            'violationCount': violation_summary['count'],
            'accountStatus': customer.get('accountStatus', 'ACTIVE'),
            'isPayable': violation_summary['isPayable'] and not requires_agent,
            'requiresAgentAssistance': requires_agent,
            'message': f"Account found with {violation_summary['count']} outstanding violation(s)"
        }
        
        return format_response(result, source, 'lookupByPlate')
        
    except Exception as e:
        logger.error(f"Error in lookupByPlate: {str(e)}", exc_info=True)
        return format_error(str(e), 'INTERNAL_ERROR', source, 500)


def get_violation_summary(client_id: str, customer_id: str) -> dict:
    """Get summary of open violations for a customer.
    
    KEY FIX: Uses balanceRemaining (if present) instead of original amount.
    This correctly reflects partial payments.
    """
    try:
        gsi2pk = f"CLIENT#{client_id}#CUST#{customer_id}"
        response = violations_table.query(
            IndexName='GSI2-Customer-Index',
            KeyConditionExpression=Key('GSI2PK').eq(gsi2pk)
        )
        
        violations = response.get('Items', [])
        open_violations = [
            v for v in violations
            if v.get('status') in ['OPEN', 'PARTIAL']
        ]
        
        # FIX: Use balanceRemaining if it exists,
        # fall back to amount for violations that
        # have never been partially paid
        total_balance = sum(
            Decimal(str(
                v.get('balanceRemaining', v.get('amount', 0))
            ))
            for v in open_violations
        )
        
        is_payable = (
            all(v.get('isPayable', True) for v in open_violations)
            and len(open_violations) > 0
        )
        
        return {
            'count': len(open_violations),
            'totalBalance': float(total_balance),
            'isPayable': is_payable
        }
    except Exception as e:
        logger.error(f"Error getting violation summary: {str(e)}")
        return {'count': 0, 'totalBalance': 0.0, 'isPayable': False}


def parse_event(event: dict) -> tuple:
    """Parse event from different sources."""
    # Bedrock Agent format
    if 'actionGroup' in event or 'function' in event:
        parameters = {}
        for param in event.get('parameters', []):
            parameters[param['name']] = param['value']
        return parameters, 'bedrock'
    
    # API Gateway format
    if 'body' in event:
        try:
            body = json.loads(event.get('body', '{}')) if event.get('body') else {}
            return body, 'apigateway'
        except json.JSONDecodeError:
            return {}, 'apigateway'
    
    return event, 'direct'


def validate_required_fields(params: dict, required_fields: list) -> str:
    """Validate required fields."""
    missing = [f for f in required_fields if not params.get(f)]
    return f"Missing required fields: {', '.join(missing)}" if missing else None


def format_response(data: dict, source: str, function_name: str) -> dict:
    """Format response based on source."""
    if source == 'bedrock':
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': 'AccountLookup',
                'function': function_name,
                'functionResponse': {
                    'responseBody': {
                        'TEXT': {
                            'body': json.dumps(data, cls=DecimalEncoder)
                        }
                    }
                }
            }
        }
    return {
        'statusCode': 200 if data.get('success', True) else 400,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*'
        },
        'body': json.dumps(data, cls=DecimalEncoder)
    }


def format_error(message: str, code: str, source: str, status_code: int = 400) -> dict:
    """Format error response."""
    error_data = {'success': False, 'error': message, 'code': code}
    if source == 'bedrock':
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': 'AccountLookup',
                'function': 'lookupByPlate',
                'functionResponse': {
                    'responseBody': {
                        'TEXT': {'body': json.dumps(error_data)}
                    }
                }
            }
        }
    return {
        'statusCode': status_code,
        'headers': {'Content-Type': 'application/json'},
        'body': json.dumps(error_data)
    }