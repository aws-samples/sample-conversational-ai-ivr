# lambda_functions/submit_dispute/index.py
"""
Tool: submitDispute
Description: Submit a new dispute for a specific violation.
             Creates dispute record and updates violation status.

Input Parameters:
  - customerId (required): Unique customer identifier
  - clientId (required): Client identifier for data isolation
  - violationId (required): Violation ID being disputed
  - disputeReason (required): Reason category (NOT_MY_VEHICLE, ALREADY_PAID, etc.)
  - disputeDetails (optional): Additional details about the dispute
  - contactPhone (optional): Contact phone for follow-up
  - contactEmail (optional): Contact email for follow-up

Output:
  - Dispute confirmation with disputeId and referenceNumber
"""

import json
import boto3
import os
import logging
import uuid
from decimal import Decimal
from datetime import datetime, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
VIOLATIONS_TABLE = os.environ.get('VIOLATIONS_TABLE')
DISPUTES_TABLE = os.environ.get('DISPUTES_TABLE')

violations_table = dynamodb.Table(VIOLATIONS_TABLE)
disputes_table = dynamodb.Table(DISPUTES_TABLE)

VALID_REASONS = [
    'NOT_MY_VEHICLE', 'ALREADY_PAID', 'INCORRECT_AMOUNT', 'SIGNAGE_ISSUE',
    'METER_MALFUNCTION', 'PERMIT_VALID', 'EMERGENCY_SITUATION', 'OTHER'
]


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def lambda_handler(event, context):
    """Main handler for submitDispute tool."""
    logger.info(f"submitDispute invoked with event: {json.dumps(event)}")
    
    params, source = parse_event(event)
    
    required_fields = ['customerId', 'clientId', 'violationId', 'disputeReason']
    validation_error = validate_required_fields(params, required_fields)
    if validation_error:
        return format_error(validation_error, 'MISSING_PARAMETERS', source)
    
    customer_id = params['customerId']
    client_id = params['clientId']
    violation_id = params['violationId']
    dispute_reason = params['disputeReason']
    dispute_details = params.get('disputeDetails', '')
    contact_phone = params.get('contactPhone')
    contact_email = params.get('contactEmail')
    
    # Validate reason
    if dispute_reason not in VALID_REASONS:
        return format_error(
            f"Invalid dispute reason. Valid: {', '.join(VALID_REASONS)}",
            'INVALID_DISPUTE_REASON', source
        )
    
    try:
        # Get violation
        violation_response = violations_table.get_item(
            Key={
                'PK': f"CLIENT#{client_id}#VIOL#{violation_id}",
                'SK': 'DETAILS'
            }
        )
        
        violation = violation_response.get('Item')
        if not violation:
            return format_error('Violation not found', 'VIOLATION_NOT_FOUND', source, 404)
        
        if violation.get('customerId') != customer_id:
            return format_error('Violation not found for customer', 'VIOLATION_NOT_FOUND', source, 404)
        
        if not violation.get('isDisputable', True):
            return format_error('This violation cannot be disputed', 'NOT_DISPUTABLE', source)
        
        if violation.get('hasActiveDispute'):
            return format_error(
                f"Dispute already exists: {violation.get('disputeId')}",
                'DISPUTE_EXISTS', source, 409
            )
        
        # Generate IDs
        dispute_id = f"disp_{uuid.uuid4().hex[:12]}"
        reference_number = f"DSP-{datetime.utcnow().strftime('%Y')}-{uuid.uuid4().hex[:6].upper()}"
        timestamp = datetime.utcnow().isoformat() + 'Z'
        est_resolution = (datetime.utcnow() + timedelta(days=14)).strftime('%Y-%m-%d')
        
        # Create dispute
        dispute_item = {
            'PK': f"CLIENT#{client_id}#DISP#{dispute_id}",
            'SK': 'DETAILS',
            'disputeId': dispute_id,
            'clientId': client_id,
            'customerId': customer_id,
            'violationId': violation_id,
            'citationNumber': violation.get('citationNumber'),
            'referenceNumber': reference_number,
            'disputeReason': dispute_reason,
            'disputeDetails': dispute_details,
            'status': 'SUBMITTED',
            'contactInfo': {'phone': contact_phone, 'email': contact_email},
            'submittedDate': timestamp,
            'lastUpdatedDate': timestamp,
            'estimatedResolutionDate': est_resolution,
            'resolution': None,
            'timeline': [{
                'date': timestamp,
                'event': 'SUBMITTED',
                'details': 'Dispute submitted via IVR',
                'actor': 'SYSTEM'
            }],
            'createdAt': timestamp,
            'updatedAt': timestamp,
            'GSI1PK': f"CLIENT#{client_id}#VIOL#{violation_id}",
            'GSI1SK': f"DISP#{dispute_id}",
            'GSI2PK': f"REF#{reference_number}",
            'GSI2SK': f"CLIENT#{client_id}"
        }
        
        disputes_table.put_item(Item=dispute_item)
        
        # Update violation
        violations_table.update_item(
            Key={
                'PK': f"CLIENT#{client_id}#VIOL#{violation_id}",
                'SK': 'DETAILS'
            },
            UpdateExpression='SET hasActiveDispute = :hd, disputeId = :did, #st = :st, updatedAt = :ua',
            ExpressionAttributeNames={'#st': 'status'},
            ExpressionAttributeValues={
                ':hd': True,
                ':did': dispute_id,
                ':st': 'DISPUTED',
                ':ua': timestamp
            }
        )
        
        result = {
            'success': True,
            'disputeId': dispute_id,
            'referenceNumber': reference_number,
            'status': 'SUBMITTED',
            'violationId': violation_id,
            'estimatedResolutionDays': 14,
            'message': f"Dispute submitted successfully. Reference: {reference_number}",
            'nextSteps': [
                'You will receive an email confirmation shortly',
                'Allow 10-14 business days for review',
                'Check status anytime using your reference number'
            ],
            'createdAt': timestamp
        }
        
        return format_response(result, source, 'submitDispute')
        
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
                'actionGroup': 'DisputeServices',
                'function': func,
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data, cls=DecimalEncoder)}}}
            }
        }
    return {
        'statusCode': 201,
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
                'function': 'submitDispute',
                'functionResponse': {'responseBody': {'TEXT': {'body': json.dumps(data)}}}
            }
        }
    return {'statusCode': status, 'headers': {'Content-Type': 'application/json'}, 'body': json.dumps(data)}