#!/usr/bin/env python3
import boto3
from decimal import Decimal

REGION = 'us-east-1'
ENVIRONMENT = 'dev'

dynamodb = boto3.resource('dynamodb', region_name=REGION)
CUSTOMERS_TABLE = f'anycompany-ivr-customers-{ENVIRONMENT}'
VIOLATIONS_TABLE = f'anycompany-ivr-violations-{ENVIRONMENT}'

def get_customer_summary():
    customers_table = dynamodb.Table(CUSTOMERS_TABLE)
    violations_table = dynamodb.Table(VIOLATIONS_TABLE)
    
    print("=" * 100)
    print(f"{'Name':<20} {'License Plate':<15} {'State':<6} {'Outstanding $':<15} {'Open Violations':<15}")
    print("=" * 100)
    
    # Query customers for CLIENT_001
    response = customers_table.query(
        KeyConditionExpression='PK = :pk AND begins_with(SK, :sk)',
        ExpressionAttributeValues={
            ':pk': 'CLIENT#CLIENT_001#CUST#',
            ':sk': 'PROFILE'
        }
    )
    
    # Fallback to scan with filter if query doesn't work
    if not response.get('Items'):
        response = customers_table.scan(
            FilterExpression='clientId = :client',
            ExpressionAttributeValues={':client': 'CLIENT_001'}
        )
    
    customers = response['Items']
    customers.sort(key=lambda x: x.get('customerName', ''))
    
    for customer in customers:
        name = customer.get('customerName', 'N/A')
        balance = customer.get('totalBalance', Decimal('0'))
        vehicles = customer.get('vehicles', [])
        customer_id = customer.get('customerId', '')
        
        plate = vehicles[0].get('licensePlate', 'N/A') if vehicles else 'N/A'
        state = vehicles[0].get('state', 'N/A') if vehicles else 'N/A'
        
        # Get open violations only
        viol_response = violations_table.query(
            IndexName='GSI2-Customer-Index',
            KeyConditionExpression='GSI2PK = :pk',
            ExpressionAttributeValues={':pk': f'CLIENT#CLIENT_001#CUST#{customer_id}'}
        )
        all_violations = viol_response.get('Items', [])
        open_violations = [v for v in all_violations if v.get('status') in ['OPEN', 'PARTIAL']]
        violation_count = len(open_violations)
        outstanding_balance = sum(float(v.get('amount', 0)) for v in open_violations)
        
        print(f"{name:<20} {plate:<15} {state:<6} ${outstanding_balance:<14.2f} {violation_count:<15}")
    
    print("=" * 100)
    
    total_customers = len(customers)
    customers_with_balance = sum(1 for c in customers if float(c.get('totalBalance', 0)) > 0)
    
    print(f"\nSummary (CLIENT_001 - Open Violations Only):")
    print(f"  Total Customers: {total_customers}")
    print(f"  Customers with Outstanding Balance: {customers_with_balance}")

if __name__ == '__main__':
    get_customer_summary()
