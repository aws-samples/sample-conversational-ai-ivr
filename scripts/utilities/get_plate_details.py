#!/usr/bin/env python3
import boto3
import sys
from boto3.dynamodb.conditions import Key
from decimal import Decimal

REGION = 'us-east-1'
ENVIRONMENT = 'dev'
CLIENT_ID = 'CLIENT_001'

dynamodb = boto3.resource('dynamodb', region_name=REGION)
CUSTOMERS_TABLE = f'anycompany-ivr-customers-{ENVIRONMENT}'
VIOLATIONS_TABLE = f'anycompany-ivr-violations-{ENVIRONMENT}'

def get_plate_details(license_plate, state):
    customers_table = dynamodb.Table(CUSTOMERS_TABLE)
    violations_table = dynamodb.Table(VIOLATIONS_TABLE)
    
    try:
        # Lookup customer by license plate
        gsi1pk = f"CLIENT#{CLIENT_ID}#PLATE#{license_plate.upper()}#{state.upper()}"
        response = customers_table.query(
            IndexName='GSI1-LicensePlate-Index',
            KeyConditionExpression=Key('GSI1PK').eq(gsi1pk)
        )
        
        if not response.get('Items'):
            print(f"❌ No account found for plate: {license_plate} ({state})")
            return
        
        customer = response['Items'][0]
        customer_id = customer['customerId']
        
        # Get violations
        viol_response = violations_table.query(
            IndexName='GSI2-Customer-Index',
            KeyConditionExpression=Key('GSI2PK').eq(f'CLIENT#{CLIENT_ID}#CUST#{customer_id}')
        )
        
        violations = viol_response.get('Items', [])
        open_violations = [v for v in violations if v.get('status') in ['OPEN', 'PARTIAL', 'DISPUTED']]
        
        # Calculate totals
        total_balance = sum(float(v.get('amount', 0)) for v in open_violations)
        total_all = sum(float(v.get('amount', 0)) for v in violations)
        
        # Display customer info
        print("=" * 100)
        print(f"CUSTOMER INFORMATION")
        print("=" * 100)
        print(f"Name:           {customer.get('customerName', 'N/A')}")
        print(f"Customer ID:    {customer_id}")
        print(f"Account Number: {customer.get('accountNumber', 'N/A')}")
        print(f"License Plate:  {license_plate.upper()} ({state.upper()})")
        print(f"Account Status: {customer.get('accountStatus', 'N/A')}")
        print(f"Email:          {customer.get('email', 'N/A')}")
        print(f"Phone:          {customer.get('phone', 'N/A')}")
        
        # Display balance summary
        print("\n" + "=" * 100)
        print(f"BALANCE SUMMARY")
        print("=" * 100)
        print(f"Total Violations:   {len(violations)}")
        print(f"Open Violations:    {len(open_violations)}")
        print(f"Outstanding:        ${total_balance:.2f}")
        print(f"Total (All):        ${total_all:.2f}")
        
        # Display violations
        if violations:
            print("\n" + "=" * 100)
            print(f"ALL VIOLATIONS ({len(violations)} total)")
            print("=" * 100)
            
            for i, v in enumerate(sorted(violations, key=lambda x: x.get('violationDate', ''), reverse=True), 1):
                location = v.get('location', {})
                loc_str = f"{location.get('address', 'N/A')}, {location.get('city', 'N/A')}, {location.get('state', 'N/A')}"
                
                print(f"\n{i}. Citation: {v.get('citationNumber', 'N/A')}")
                print(f"   Violation ID:   {v.get('violationId', 'N/A')}")
                print(f"   Type:           {v.get('violationType', 'N/A')}")
                print(f"   Amount:         ${float(v.get('amount', 0)):.2f}")
                print(f"   Original:       ${float(v.get('originalAmount', 0)):.2f}")
                print(f"   Late Fees:      ${float(v.get('lateFees', 0)):.2f}")
                print(f"   Date:           {v.get('violationDate', 'N/A')}")
                print(f"   Due Date:       {v.get('dueDate', 'N/A')}")
                print(f"   Location:       {loc_str}")
                print(f"   Status:         {v.get('status', 'N/A')}")
                print(f"   Payable:        {'Yes' if v.get('isPayable', True) else 'No'}")
                print(f"   Disputable:     {'Yes' if v.get('isDisputable', True) else 'No'}")
                if v.get('hasActiveDispute'):
                    print(f"   Active Dispute: {v.get('disputeId', 'N/A')}")
        else:
            print("\n✅ No violations found")
        
        print("\n" + "=" * 100)
        
    except Exception as e:
        print(f"❌ Error: {str(e)}")

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python3 get_plate_details.py <license_plate> <state>")
        print("Example: python3 get_plate_details.py ABC1234 FL")
        sys.exit(1)
    
    plate = sys.argv[1]
    state = sys.argv[2]
    get_plate_details(plate, state)
