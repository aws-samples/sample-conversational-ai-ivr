# lambda_functions/get_violation_details/index.py
"""
Tool: getViolationDetails
Description: Get detailed information about violations for a customer.
             Includes violation type, amount, date, location, and payment eligibility.

Input Parameters:
  - customerId (required): Unique customer identifier
  - clientId (required): Client identifier for data isolation
  - violationId (optional): Specific violation ID to retrieve
  - includeHistory (optional): Include payment history (default: false)

Output:
  - List of violations with detailed information
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
VIOLATIONS_TABLE = os.environ.get('VIOLATIONS_TABLE')
violations_table = dynamodb.Table(VIOLATIONS_TABLE)


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def lambda_handler(event, context):
    """Main handler for getViolationDetails tool."""
    logger.info(f"getViolationDetails invoked with event: {json.dumps(event)}")
    
    params, source = parse_event(event)
    
    required_fields = ['customerId', 'clientId']
    validation_error = validate_required_fields(params, required_fields)
    if validation_error:
        return format_error(validation_error, 'MISSING_PARAMETERS', source)
    
    customer_id = params['customerId']
    client_id = params['clientId']
    violation_id = params.get('violationId')
    include_history = params.get('includeHistory', False)
    if isinstance(include_history, str):
        include_history = include_history.lower() == 'true'
    
    try:
        if violation_id:
            response = violations_table.get_item(
                Key={
                    'PK': f"CLIENT#{client_id}#VIOL#{violation_id}",
                    'SK': 'DETAILS'
                }
            )
            violation = response.get('Item')
            if not violation:
                return format_error('Violation not found', 'VIOLATION_NOT_FOUND', source, 404)
            if violation.get('customerId') != customer_id:
                return format_error('Violation not found for customer', 'VIOLATION_NOT_FOUND', source, 404)
            violations = [violation]
        else:
            response = violations_table.query(
                IndexName='GSI2-Customer-Index',
                KeyConditionExpression=Key('GSI2PK').eq(
                    f"CLIENT#{client_id}#CUST#{customer_id}"
                )
            )
            violations = response.get('Items', [])
        
        # Filter to open/partial/disputed
        open_violations = [
            v for v in violations
            if v.get('status') in ['OPEN', 'PARTIAL', 'DISPUTED']
        ]
        
        formatted = []
        for v in open_violations:
            loc = v.get('location', {})
            loc_str = ', '.join(filter(None, [
                loc.get('address'), loc.get('city'), loc.get('state')
            ]))
            
            # ──────────────────────────────────────────────
            # KEY FIX: Use balanceRemaining for the amount
            # shown to the caller. Fall back to amount if
            # balanceRemaining doesn't exist yet (never
            # partially paid).
            # ──────────────────────────────────────────────
            original_amount = float(v.get('amount', 0))
            balance_remaining = float(
                v.get('balanceRemaining', v.get('amount', 0))
            )
            
            item = {
                'violationId':     v.get('violationId'),
                'citationNumber':  v.get('citationNumber'),
                'violationType':   v.get('violationType'),
                'amount':          balance_remaining,       # ← FIX: was original_amount
                'originalAmount':  original_amount,         # Keep original for reference
                'balanceRemaining': balance_remaining,      # ← NEW: explicit field
                'lateFees':        float(v.get('lateFees', 0)),
                'violationDate':   v.get('violationDate'),
                'dueDate':         v.get('dueDate'),
                'location':        loc_str,
                'licensePlate':    v.get('vehicle', {}).get('licensePlate'),
                'vehicleState':    v.get('vehicle', {}).get('state'),
                'status':          v.get('status'),
                'isPayable':       v.get('isPayable', True),
                'isDisputable':    v.get('isDisputable', True),
                'hasActiveDispute': v.get('hasActiveDispute', False),
                'disputeId':       v.get('disputeId')
            }
            if include_history:
                item['paymentHistory'] = v.get('paymentHistory', [])
            formatted.append(item)
        
        formatted.sort(
            key=lambda x: x.get('violationDate', ''),
            reverse=True
        )
        
        # FIX: Sum balanceRemaining, not original amount
        total_amount = sum(v['balanceRemaining'] for v in formatted)
        
        result = {
            'success':     True,
            'customerId':  customer_id,
            'violations':  formatted,
            'totalCount':  len(formatted),
            'totalAmount': total_amount,
            'message':     f"Found {len(formatted)} violation(s) totaling ${total_amount:.2f}"
        }
        
        return format_response(result, source, 'getViolationDetails')
        
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
                'function': 'getViolationDetails',
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data)}}}
            }
        }
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(data)}