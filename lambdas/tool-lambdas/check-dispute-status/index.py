# lambda_functions/check_dispute_status/index.py
"""
Tool: checkDisputeStatus
Description: Check the status of an existing dispute.
             Can lookup by disputeId, violationId, or referenceNumber.

Input Parameters:
  - clientId (required): Client identifier for data isolation
  - disputeId (optional): Unique dispute identifier
  - violationId (optional): Original violation ID
  - referenceNumber (optional): Customer reference number
  - customerId (optional): Customer ID for verification

Output:
  - Dispute status, timeline, and resolution details
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
DISPUTES_TABLE = os.environ.get('DISPUTES_TABLE')
disputes_table = dynamodb.Table(DISPUTES_TABLE)


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def lambda_handler(event, context):
    """Main handler for checkDisputeStatus tool."""
    logger.info(f"checkDisputeStatus invoked with event: {json.dumps(event)}")
    
    params, source = parse_event(event)
    
    client_id = params.get('clientId')
    if not client_id:
        return format_error('Missing required field: clientId', 'MISSING_PARAMETERS', source)
    
    dispute_id = params.get('disputeId')
    violation_id = params.get('violationId')
    reference_number = params.get('referenceNumber')
    customer_id = params.get('customerId')
    
    if not any([dispute_id, violation_id, reference_number]):
        return format_error(
            'Must provide disputeId, violationId, or referenceNumber',
            'MISSING_PARAMETERS', source
        )
    
    try:
        dispute = None
        
        if dispute_id:
            response = disputes_table.get_item(
                Key={
                    'PK': f"CLIENT#{client_id}#DISP#{dispute_id}",
                    'SK': 'DETAILS'
                }
            )
            dispute = response.get('Item')
            
        elif reference_number:
            response = disputes_table.query(
                IndexName='GSI2-Reference-Index',
                KeyConditionExpression=Key('GSI2PK').eq(f"REF#{reference_number}")
            )
            items = response.get('Items', [])
            dispute = items[0] if items else None
            
        elif violation_id:
            response = disputes_table.query(
                IndexName='GSI1-Violation-Index',
                KeyConditionExpression=Key('GSI1PK').eq(f"CLIENT#{client_id}#VIOL#{violation_id}")
            )
            items = response.get('Items', [])
            if items:
                dispute = sorted(items, key=lambda x: x.get('createdAt', ''), reverse=True)[0]
        
        if not dispute:
            result = {
                'success': True,
                'disputeFound': False,
                'message': 'No dispute found with the provided information',
                'suggestions': [
                    'Verify the reference number is correct',
                    'Try using the violation ID',
                    'Contact customer service for assistance'
                ]
            }
            return format_response(result, source, 'checkDisputeStatus')
        
        # Verify customer if provided
        if customer_id and dispute.get('customerId') != customer_id:
            result = {
                'success': True,
                'disputeFound': False,
                'message': 'No dispute found for this customer'
            }
            return format_response(result, source, 'checkDisputeStatus')
        
        status_messages = {
            'SUBMITTED': 'Your dispute has been submitted and is awaiting review',
            'PENDING_REVIEW': 'Your dispute is in the queue for review',
            'UNDER_REVIEW': 'Your dispute is currently being reviewed',
            'RESOLVED': 'Your dispute has been resolved',
            'REJECTED': 'Your dispute was reviewed but could not be approved'
        }
        
        result = {
            'success': True,
            'disputeFound': True,
            'disputeId': dispute.get('disputeId'),
            'referenceNumber': dispute.get('referenceNumber'),
            'violationId': dispute.get('violationId'),
            'citationNumber': dispute.get('citationNumber'),
            'status': dispute.get('status'),
            'disputeReason': dispute.get('disputeReason'),
            'disputeDetails': dispute.get('disputeDetails'),
            'submittedDate': dispute.get('submittedDate'),
            'lastUpdatedDate': dispute.get('lastUpdatedDate'),
            'estimatedResolutionDate': dispute.get('estimatedResolutionDate'),
            'resolution': dispute.get('resolution'),
            'timeline': dispute.get('timeline', []),
            'message': status_messages.get(dispute.get('status'), 'Dispute is being processed')
        }
        
        return format_response(result, source, 'checkDisputeStatus')
        
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


def format_response(data, source, func):
    if source == 'bedrock':
        return {
            'messageVersion': '1.0',
            'response': {
                'actionGroup': 'DisputeServices',
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
                'actionGroup': 'DisputeServices',
                'function': 'checkDisputeStatus',
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data)}}}
            }
        }
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(data)}