#!/usr/bin/env python3
import boto3
import sys
from boto3.dynamodb.conditions import Key
from datetime import datetime, timezone
from decimal import Decimal

REGION = 'us-east-1'
ENVIRONMENT = 'dev'
CLIENT_ID = 'CLIENT_001'

dynamodb = boto3.resource('dynamodb', region_name=REGION)
CUSTOMERS_TABLE = f'anycompany-ivr-customers-{ENVIRONMENT}'
VIOLATIONS_TABLE = f'anycompany-ivr-violations-{ENVIRONMENT}'


def reset_paid_to_open(license_plate, state):
    customers_table = dynamodb.Table(CUSTOMERS_TABLE)
    violations_table = dynamodb.Table(VIOLATIONS_TABLE)
    now = datetime.now(timezone.utc).isoformat()

    # Lookup customer by plate
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
    print(f"✅ Found customer: {customer.get('customerName')} (ID: {customer_id})")

    # Get violations
    viol_response = violations_table.query(
        IndexName='GSI2-Customer-Index',
        KeyConditionExpression=Key('GSI2PK').eq(f'CLIENT#{CLIENT_ID}#CUST#{customer_id}')
    )

    violations = viol_response.get('Items', [])
    paid_violations = [v for v in violations if v.get('status') == 'PAID']

    if not paid_violations:
        print("ℹ️  No PAID violations found to reset.")
        return

    print(f"\nFound {len(paid_violations)} PAID violation(s) to reset:\n")

    balance_restored = Decimal('0')

    for v in paid_violations:
        viol_id = v['violationId']
        pk = f"CLIENT#{CLIENT_ID}#VIOL#{viol_id}"
        original_amount = v.get('originalAmount', v.get('amount', Decimal('0')))
        late_fees = v.get('lateFees', Decimal('0'))
        restore_amount = Decimal(str(original_amount)) + Decimal(str(late_fees))

        violations_table.update_item(
            Key={'PK': pk, 'SK': 'DETAILS'},
            UpdateExpression=(
                'SET #st = :status, '
                'updatedAt = :now, '
                'balanceRemaining = :amount, '
                'isPayable = :payable'
            ),
            ExpressionAttributeNames={'#st': 'status'},
            ExpressionAttributeValues={
                ':status': 'OPEN',
                ':now': now,
                ':amount': restore_amount,
                ':payable': True,
            }
        )

        balance_restored += restore_amount
        print(f"  🔄 {viol_id} (Citation: {v.get('citationNumber', 'N/A')}) "
              f"PAID → OPEN  ${restore_amount:.2f}")

    # Update customer totalBalance
    customers_table.update_item(
        Key={
            'PK': f'CLIENT#{CLIENT_ID}#CUST#{customer_id}',
            'SK': 'PROFILE'
        },
        UpdateExpression='SET totalBalance = if_not_exists(totalBalance, :zero) + :amount, updatedAt = :now',
        ExpressionAttributeValues={
            ':amount': balance_restored,
            ':now': now,
            ':zero': Decimal('0'),
        }
    )

    print(f"\n✅ Reset {len(paid_violations)} violation(s). "
          f"Customer balance restored by ${balance_restored:.2f}")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: python3 reset_paid_to_open.py <license_plate> <state>")
        print("Example: python3 reset_paid_to_open.py ABC1234 FL")
        sys.exit(1)

    reset_paid_to_open(sys.argv[1], sys.argv[2])
