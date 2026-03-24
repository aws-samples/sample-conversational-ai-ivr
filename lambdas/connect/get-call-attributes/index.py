# lambda_functions/get_call_attributes/index.py
"""
Lambda function to retrieve client configuration based on dialed phone number.
This is invoked at the start of every call to determine which client the caller
is trying to reach and what services are available.

UPDATED: Uses zoneinfo instead of pytz (built into Python 3.9+)
"""

import json
import boto3
import os
import logging
from datetime import datetime
from zoneinfo import ZoneInfo  # Built into Python 3.9+ (no pip install needed!)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
CLIENT_CONFIG_TABLE = os.environ.get('CLIENT_CONFIG_TABLE', 'anycompany-ivr-client-config-dev')


def lambda_handler(event, context):
    """
    Main handler - retrieves client configuration based on dialed number.
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        # Extract dialed number from Connect event
        contact_data = event.get('Details', {}).get('ContactData', {})
        system_endpoint = contact_data.get('SystemEndpoint', {})
        dialed_number = system_endpoint.get('Address', '')
        
        contact_id = contact_data.get('ContactId', '')
        
        logger.info(f"Dialed number: {dialed_number}, Contact ID: {contact_id}")
        
        if not dialed_number:
            logger.error("No dialed number found in event")
            return get_default_response("Unknown")
        
        # Query DynamoDB for client configuration
        client_config = get_client_config_by_phone(dialed_number)
        
        if not client_config:
            logger.warning(f"No client config found for number: {dialed_number}")
            return get_default_response(dialed_number)
        
        # Check if office is currently open
        is_open = check_business_hours(client_config)
        
        # Determine authentication method based on client type
        auth_method = get_auth_method(client_config)
        
        # Format available tools as comma-separated string
        available_tools = client_config.get('availableTools', [])
        if isinstance(available_tools, list):
            available_tools = ','.join(available_tools)
        
        # Build response - ALL VALUES MUST BE STRINGS for Connect
        response = {
            'clientId': str(client_config.get('clientId', '')),
            'clientName': str(client_config.get('clientName', '')),
            'clientType': str(client_config.get('clientType', 'servicing')),
            'greetingMessage': str(client_config.get('greetingMessage', '')),
            'availableTools': str(available_tools),
            'escalationQueue': str(client_config.get('escalationQueue', 'Default_Queue')),
            'maxViolationsIVR': str(client_config.get('maxViolationsIVR', 10)),
            'isOpen': str(is_open).lower(),  # "true" or "false"
            'authMethod': str(auth_method),
            'settlementEnabled': str(client_config.get('settlementEnabled', False)).lower(),
            'paymentHandling': str(client_config.get('paymentHandling', 'internal')),
            'transferNumber': str(client_config.get('transferNumber', '')),
            'lookupStatus': 'SUCCESS'
        }
        
        logger.info(f"Returning response: {json.dumps(response)}")
        return response
        
    except Exception as e:
        logger.error(f"Error in getCallAttributes: {str(e)}", exc_info=True)
        return get_default_response("Error")


def get_client_config_by_phone(phone_number: str) -> dict:
    """Query DynamoDB for client configuration by phone number."""
    table = dynamodb.Table(CLIENT_CONFIG_TABLE)
    
    # Clean phone number (ensure E.164 format)
    clean_number = phone_number.replace(' ', '').replace('-', '').replace('(', '').replace(')', '')
    if not clean_number.startswith('+'):
        if len(clean_number) == 10:
            clean_number = '+1' + clean_number
        elif len(clean_number) == 11 and clean_number.startswith('1'):
            clean_number = '+' + clean_number
        else:
            clean_number = '+' + clean_number
    
    logger.info(f"Looking up client config for: {clean_number}")
    
    try:
        # Query using GSI on phone number
        response = table.query(
            IndexName='PhoneNumber-Index',
            KeyConditionExpression='phoneNumber = :phone',
            ExpressionAttributeValues={
                ':phone': clean_number
            }
        )
        
        items = response.get('Items', [])
        if items:
            logger.info(f"Found client config: {items[0].get('clientId')}")
            return items[0]
        
        # Try without country code
        if clean_number.startswith('+1'):
            alt_number = clean_number[2:]  # Remove +1
            logger.info(f"Trying alternate format: {alt_number}")
            response = table.query(
                IndexName='PhoneNumber-Index',
                KeyConditionExpression='phoneNumber = :phone',
                ExpressionAttributeValues={
                    ':phone': alt_number
                }
            )
            items = response.get('Items', [])
            if items:
                return items[0]
        
        logger.warning(f"No client config found for any format of: {phone_number}")
        return None
        
    except Exception as e:
        logger.error(f"Error querying client config: {str(e)}")
        return None


def check_business_hours(client_config: dict) -> bool:
    """Check if the client's office is currently open using zoneinfo."""
    business_hours = client_config.get('businessHours', {})
    
    if not business_hours:
        logger.info("No business hours configured, defaulting to open")
        return True  # Default to open if no hours specified
    
    timezone_str = business_hours.get('timezone', 'America/New_York')
    schedule = business_hours.get('schedule', {})
    
    try:
        # Use zoneinfo instead of pytz
        try:
            tz = ZoneInfo(timezone_str)
        except Exception:
            logger.warning(f"Invalid timezone: {timezone_str}, using America/New_York")
            tz = ZoneInfo('America/New_York')
        
        now = datetime.now(tz)
        
        # Get day name (lowercase)
        day_name = now.strftime('%A').lower()
        
        day_schedule = schedule.get(day_name)
        
        if day_schedule is None:
            logger.info(f"No schedule for {day_name}, returning closed")
            return False  # Closed on this day
        
        open_time_str = day_schedule.get('open', '00:00')
        close_time_str = day_schedule.get('close', '23:59')
        
        # Parse times
        open_time = datetime.strptime(open_time_str, '%H:%M').time()
        close_time = datetime.strptime(close_time_str, '%H:%M').time()
        current_time = now.time()
        
        is_open = open_time <= current_time <= close_time
        
        logger.info(f"Business hours check - Day: {day_name}, "
                   f"Current: {current_time}, Open: {open_time}, "
                   f"Close: {close_time}, IsOpen: {is_open}")
        
        return is_open
        
    except Exception as e:
        logger.error(f"Error checking business hours: {str(e)}")
        return True  # Default to open on error


def get_auth_method(client_config: dict) -> str:
    """Determine authentication method based on client type and config."""
    client_type = client_config.get('clientType', 'servicing')
    auth_fields = client_config.get('authenticationFields', [])
    
    if client_type == 'collections':
        return 'account_zip'
    
    # Check authentication fields
    field_names = [f.get('fieldName', '').lower() for f in auth_fields]
    
    if 'accountnumber' in field_names:
        return 'account_zip'
    elif 'citationnumber' in field_names or 'citation' in field_names:
        return 'citation'
    else:
        return 'plate_state'


def get_default_response(identifier: str) -> dict:
    """Return default response when client config is not found."""
    logger.warning(f"Returning default response for: {identifier}")
    return {
        'clientId': 'DEFAULT',
        'clientName': 'AnyCompany Services',
        'clientType': 'servicing',
        'greetingMessage': 'Welcome to AnyCompany Services. How can I help you today?',
        'availableTools': 'balanceInquiry',
        'escalationQueue': 'Default_Queue',
        'maxViolationsIVR': '10',
        'isOpen': 'true',
        'authMethod': 'plate_state',
        'settlementEnabled': 'false',
        'paymentHandling': 'transfer',
        'transferNumber': '',
        'lookupStatus': 'NOT_FOUND'
    }
