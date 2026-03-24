#!/usr/bin/env python3
"""Update the license plate number for a customer identified by their current plate."""

import boto3
import json
import sys
from boto3.dynamodb.conditions import Key

REGION = 'us-east-1'
ENVIRONMENT = 'dev'
CLIENT_ID = 'CLIENT_001'

dynamodb = boto3.resource('dynamodb', region_name=REGION)
customers_table = dynamodb.Table(f'anycompany-ivr-customers-{ENVIRONMENT}')
violations_table = dynamodb.Table(f'anycompany-ivr-violations-{ENVIRONMENT}')


def update_license_plate(current_plate, state, new_plate):
    # 1. Find customer by current plate via GSI1
    gsi1pk = f"CLIENT#{CLIENT_ID}#PLATE#{current_plate}#{state}"
    resp = customers_table.query(
        IndexName='GSI1-LicensePlate-Index',
        KeyConditionExpression=Key('GSI1PK').eq(gsi1pk)
    )

    if not resp.get('Items'):
        print(f"No customer found with plate {current_plate} ({state})")
        return

    customer = resp['Items'][0]
    pk = customer['PK']
    sk = customer['SK']
    print(f"Found: {customer['customerName']} (ID: {customer['customerId']})")

    # 2. Update vehicles list with new plate
    vehicles = customer.get('vehicles', [])
    for v in vehicles:
        if v.get('licensePlate') == current_plate and v.get('state') == state:
            v['licensePlate'] = new_plate
            break

    # 3. Update customer record: vehicles list + GSI1PK
    new_gsi1pk = f"CLIENT#{CLIENT_ID}#PLATE#{new_plate}#{state}"
    customers_table.update_item(
        Key={'PK': pk, 'SK': sk},
        UpdateExpression='SET vehicles = :v, GSI1PK = :g',
        ExpressionAttributeValues={
            ':v': vehicles,
            ':g': new_gsi1pk
        }
    )
    print(f"Updated plate: {current_plate} -> {new_plate}")

    # 4. Update violations that reference this plate
    cust_id = customer['customerId']
    gsi2pk = f"CLIENT#{CLIENT_ID}#CUST#{cust_id}"
    viol_resp = violations_table.query(
        IndexName='GSI2-Customer-Index',
        KeyConditionExpression=Key('GSI2PK').eq(gsi2pk)
    )
    updated = 0
    for viol in viol_resp.get('Items', []):
        veh = viol.get('vehicle', {})
        if veh.get('licensePlate') == current_plate and veh.get('state') == state:
            veh['licensePlate'] = new_plate
            violations_table.update_item(
                Key={'PK': viol['PK'], 'SK': viol['SK']},
                UpdateExpression='SET vehicle = :v',
                ExpressionAttributeValues={':v': veh}
            )
            updated += 1
    print(f"Updated {updated} violation record(s)")


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print("Usage: python update_license_plate.py <current_plate> <state> <new_plate>")
        print("Example: python update_license_plate.py ABC1234 FL XYZ9999")
        sys.exit(1)

    update_license_plate(sys.argv[1].upper(), sys.argv[2].upper(), sys.argv[3].upper())
