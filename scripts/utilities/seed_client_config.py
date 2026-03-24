#!/usr/bin/env python3
"""
Seed client configuration data into DynamoDB.
This populates the client-config table with sample clients.
"""

import argparse
import boto3
import json
from datetime import datetime


def create_client_configs():
    """Define client configurations."""
    
    return [
        # ===========================================
        # CLIENT 1: Metro Parking Authority (Servicing)
        # ===========================================
        {
            'clientId': 'CLIENT_001',
            'clientName': 'Metro Parking Authority',
            'clientType': 'servicing',
            'phoneNumber': '+18445936943',
            'greetingMessage': (
                'Welcome to Metro Parking Authority. '
                'I can help you check your balance, review your violations, or submit a dispute. '
                'How can I assist you today?'
            ),
            'authenticationFields': [
                {
                    'fieldName': 'licensePlate',
                    'prompt': 'Please provide your license plate number',
                    'validation': 'alphanumeric',
                    'required': True
                },
                {
                    'fieldName': 'state',
                    'prompt': 'What state is your vehicle registered in?',
                    'validation': 'usState',
                    'required': True
                }
            ],
            'availableTools': [
                'lookupByPlate',
                'lookupByCitation',
                'getBalance',
                'getViolationDetails',
                'submitDispute',
                'checkDisputeStatus'
            ],
            'paymentHandling': 'internal',
            'maxViolationsIVR': 10,
            'settlementEnabled': False,
            'transferNumber': None,
            'escalationQueue': 'MetroParking_Queue',
            'businessHours': {
                'timezone': 'America/New_York',
                'schedule': {
                    'monday': {'open': '08:00', 'close': '18:00'},
                    'tuesday': {'open': '08:00', 'close': '18:00'},
                    'wednesday': {'open': '08:00', 'close': '18:00'},
                    'thursday': {'open': '08:00', 'close': '18:00'},
                    'friday': {'open': '08:00', 'close': '17:00'},
                    'saturday': {'open': '09:00', 'close': '13:00'},
                    'sunday': None
                }
            },
            'createdAt': datetime.utcnow().isoformat() + 'Z',
            'updatedAt': datetime.utcnow().isoformat() + 'Z',
            'isActive': True
        },
        
        # ===========================================
        # CLIENT 2: City Collections Agency (Collections)
        # ===========================================
        {
            'clientId': 'CLIENT_002',
            'clientName': 'City Collections Agency',
            'clientType': 'collections',
            'phoneNumber': '+18005550002',
            'greetingMessage': (
                'Welcome to City Collections Agency. '
                'I can help you check your account balance and review your account details. '
                'How can I help you today?'
            ),
            'authenticationFields': [
                {
                    'fieldName': 'accountNumber',
                    'prompt': 'Please provide your account number',
                    'validation': 'alphanumeric',
                    'required': True
                },
                {
                    'fieldName': 'zipCode',
                    'prompt': 'What is your billing zip code?',
                    'validation': 'zipCode',
                    'required': True
                }
            ],
            'availableTools': [
                'lookupByAccount',
                'getBalance',
                'getViolationDetails'
            ],
            'paymentHandling': 'transfer',
            'maxViolationsIVR': 5,
            'settlementEnabled': True,
            'transferNumber': '+18005559999',
            'escalationQueue': 'Collections_Queue',
            'businessHours': {
                'timezone': 'America/New_York',
                'schedule': {
                    'monday': {'open': '09:00', 'close': '17:00'},
                    'tuesday': {'open': '09:00', 'close': '17:00'},
                    'wednesday': {'open': '09:00', 'close': '17:00'},
                    'thursday': {'open': '09:00', 'close': '17:00'},
                    'friday': {'open': '09:00', 'close': '17:00'},
                    'saturday': None,
                    'sunday': None
                }
            },
            'createdAt': datetime.utcnow().isoformat() + 'Z',
            'updatedAt': datetime.utcnow().isoformat() + 'Z',
            'isActive': True
        },
        
        # ===========================================
        # CLIENT 3: Highway Toll Authority (Servicing)
        # ===========================================
        {
            'clientId': 'CLIENT_003',
            'clientName': 'Highway Toll Authority',
            'clientType': 'servicing',
            'phoneNumber': '+18005550003',
            'greetingMessage': (
                'Thank you for calling Highway Toll Authority. '
                'I can help you with your toll violations and account inquiries. '
                'How may I assist you?'
            ),
            'authenticationFields': [
                {
                    'fieldName': 'licensePlate',
                    'prompt': 'Please provide your license plate number',
                    'validation': 'alphanumeric',
                    'required': True
                },
                {
                    'fieldName': 'state',
                    'prompt': 'What state is your vehicle registered in?',
                    'validation': 'usState',
                    'required': True
                }
            ],
            'availableTools': [
                'lookupByPlate',
                'lookupByCitation',
                'getBalance',
                'getViolationDetails',
                'submitDispute',
                'checkDisputeStatus'
            ],
            'paymentHandling': 'internal',
            'maxViolationsIVR': 15,
            'settlementEnabled': False,
            'transferNumber': None,
            'escalationQueue': 'TollAuthority_Queue',
            'businessHours': {
                'timezone': 'America/New_York',
                'schedule': {
                    'monday': {'open': '07:00', 'close': '19:00'},
                    'tuesday': {'open': '07:00', 'close': '19:00'},
                    'wednesday': {'open': '07:00', 'close': '19:00'},
                    'thursday': {'open': '07:00', 'close': '19:00'},
                    'friday': {'open': '07:00', 'close': '19:00'},
                    'saturday': {'open': '08:00', 'close': '16:00'},
                    'sunday': {'open': '10:00', 'close': '14:00'}
                }
            },
            'createdAt': datetime.utcnow().isoformat() + 'Z',
            'updatedAt': datetime.utcnow().isoformat() + 'Z',
            'isActive': True
        },
        
        # ===========================================
        # DEFAULT CLIENT (Fallback)
        # ===========================================
        {
            'clientId': 'DEFAULT',
            'clientName': 'AnyCompany Services',
            'clientType': 'servicing',
            'phoneNumber': '+18005550000',
            'greetingMessage': (
                'Welcome to AnyCompany Services. '
                'How can I help you today?'
            ),
            'authenticationFields': [
                {
                    'fieldName': 'licensePlate',
                    'prompt': 'Please provide your license plate number',
                    'validation': 'alphanumeric',
                    'required': True
                },
                {
                    'fieldName': 'state',
                    'prompt': 'What state is your vehicle registered in?',
                    'validation': 'usState',
                    'required': True
                }
            ],
            'availableTools': [
                'lookupByPlate',
                'getBalance',
                'getViolationDetails'
            ],
            'paymentHandling': 'transfer',
            'maxViolationsIVR': 10,
            'settlementEnabled': False,
            'transferNumber': None,
            'escalationQueue': 'Default_Queue',
            'businessHours': {
                'timezone': 'America/New_York',
                'schedule': {
                    'monday': {'open': '00:00', 'close': '23:59'},
                    'tuesday': {'open': '00:00', 'close': '23:59'},
                    'wednesday': {'open': '00:00', 'close': '23:59'},
                    'thursday': {'open': '00:00', 'close': '23:59'},
                    'friday': {'open': '00:00', 'close': '23:59'},
                    'saturday': {'open': '00:00', 'close': '23:59'},
                    'sunday': {'open': '00:00', 'close': '23:59'}
                }
            },
            'createdAt': datetime.utcnow().isoformat() + 'Z',
            'updatedAt': datetime.utcnow().isoformat() + 'Z',
            'isActive': True
        }
    ]


def seed_data(environment: str, region: str):
    """Seed client configuration data into DynamoDB."""
    
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table_name = f'anycompany-ivr-client-config-{environment}'
    table = dynamodb.Table(table_name)
    
    print(f"Seeding client configuration data to: {table_name}")
    print("=" * 60)
    
    clients = create_client_configs()
    
    for client in clients:
        try:
            table.put_item(Item=client)
            print(f"✅ Created: {client['clientId']} - {client['clientName']}")
            print(f"   Phone: {client['phoneNumber']}")
            print(f"   Type: {client['clientType']}")
            print(f"   Tools: {', '.join(client['availableTools'])}")
            print()
        except Exception as e:
            print(f"❌ Error creating {client['clientId']}: {str(e)}")
    
    print("=" * 60)
    print(f"✅ Seeded {len(clients)} client configurations!")
    
    # Verify data
    print("\nVerifying data...")
    for client in clients:
        response = table.get_item(Key={'clientId': client['clientId']})
        if response.get('Item'):
            print(f"  ✓ {client['clientId']} verified")
        else:
            print(f"  ✗ {client['clientId']} NOT FOUND")


def list_clients(environment: str, region: str):
    """List all client configurations."""
    
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table_name = f'anycompany-ivr-client-config-{environment}'
    table = dynamodb.Table(table_name)
    
    print(f"Listing clients from: {table_name}")
    print("=" * 60)
    
    response = table.scan()
    items = response.get('Items', [])
    
    for item in items:
        print(f"Client ID: {item.get('clientId')}")
        print(f"  Name: {item.get('clientName')}")
        print(f"  Type: {item.get('clientType')}")
        print(f"  Phone: {item.get('phoneNumber')}")
        print(f"  Tools: {item.get('availableTools')}")
        print(f"  Queue: {item.get('escalationQueue')}")
        print()
    
    print(f"Total clients: {len(items)}")


def test_phone_lookup(environment: str, region: str, phone_number: str):
    """Test phone number lookup via GSI."""
    
    dynamodb = boto3.resource('dynamodb', region_name=region)
    table_name = f'anycompany-ivr-client-config-{environment}'
    table = dynamodb.Table(table_name)
    
    print(f"Testing phone lookup: {phone_number}")
    print("=" * 60)
    
    # Normalize phone number
    if not phone_number.startswith('+'):
        phone_number = '+1' + phone_number.lstrip('1')
    
    response = table.query(
        IndexName='PhoneNumber-Index',
        KeyConditionExpression=boto3.dynamodb.conditions.Key('phoneNumber').eq(phone_number)
    )
    
    items = response.get('Items', [])
    
    if items:
        client = items[0]
        print(f"✅ Found client!")
        print(f"  Client ID: {client.get('clientId')}")
        print(f"  Name: {client.get('clientName')}")
        print(f"  Type: {client.get('clientType')}")
        print(f"  Greeting: {client.get('greetingMessage')[:50]}...")
    else:
        print(f"❌ No client found for phone: {phone_number}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Manage client configuration data')
    parser.add_argument('--environment', '-e', default='dev', help='Environment (dev/staging/prod)')
    parser.add_argument('--region', '-r', default='us-east-1', help='AWS Region')
    parser.add_argument('--action', '-a', default='seed', 
                       choices=['seed', 'list', 'test'],
                       help='Action to perform')
    parser.add_argument('--phone', '-p', help='Phone number for test lookup')
    
    args = parser.parse_args()
    
    if args.action == 'seed':
        seed_data(args.environment, args.region)
    elif args.action == 'list':
        list_clients(args.environment, args.region)
    elif args.action == 'test':
        if not args.phone:
            print("Error: --phone required for test action")
            exit(1)
        test_phone_lookup(args.environment, args.region, args.phone)