#!/usr/bin/env python3
import boto3
import random
from decimal import Decimal
from datetime import datetime, timedelta

REGION = 'us-east-1'
ENVIRONMENT = 'dev'

dynamodb = boto3.resource('dynamodb', region_name=REGION)
CUSTOMERS_TABLE = f'anycompany-ivr-customers-{ENVIRONMENT}'
VIOLATIONS_TABLE = f'anycompany-ivr-violations-{ENVIRONMENT}'

STATES = ['FL', 'CA', 'NY', 'TX', 'GA', 'IL', 'PA', 'OH', 'NC', 'MI']
CITIES = {'FL': ['Miami', 'Orlando', 'Tampa'], 'CA': ['Los Angeles', 'San Diego', 'San Francisco'], 
          'NY': ['New York', 'Buffalo', 'Albany'], 'TX': ['Houston', 'Dallas', 'Austin'],
          'GA': ['Atlanta', 'Savannah', 'Augusta'], 'IL': ['Chicago', 'Springfield', 'Naperville'],
          'PA': ['Philadelphia', 'Pittsburgh', 'Allentown'], 'OH': ['Columbus', 'Cleveland', 'Cincinnati'],
          'NC': ['Charlotte', 'Raleigh', 'Durham'], 'MI': ['Detroit', 'Grand Rapids', 'Ann Arbor']}
VIOLATION_TYPES = ['PARKING', 'SPEEDING', 'RED_LIGHT', 'TOLL', 'EXPIRED_METER']
VEHICLES = [('Toyota', 'Camry'), ('Honda', 'Accord'), ('Ford', 'F150'), ('Chevrolet', 'Silverado'),
            ('Tesla', 'Model3'), ('BMW', 'X5'), ('Mercedes', 'C-Class'), ('Nissan', 'Altima')]


def clean_none(d):
    """Remove None values recursively — DynamoDB doesn't support None."""
    if isinstance(d, dict):
        return {k: clean_none(v) for k, v in d.items() if v is not None}
    elif isinstance(d, list):
        return [clean_none(i) for i in d]
    return d


def generate_plate(state):
    letters = ''.join(random.choices('ABCDEFGHIJKLMNOPQRSTUVWXYZ', k=3))
    numbers = ''.join(random.choices('0123456789', k=4))
    return f"{letters}{numbers}"


def seed_data():
    customers_table = dynamodb.Table(CUSTOMERS_TABLE)
    violations_table = dynamodb.Table(VIOLATIONS_TABLE)
    timestamp = datetime.now().isoformat() + 'Z'
    
    print("Seeding 25 customers with violations...")
    
    for i in range(1, 26):
        cust_id = f"cust_{i:03d}"
        state = random.choice(STATES)
        city = random.choice(CITIES[state])
        plate = generate_plate(state)
        make, model = random.choice(VEHICLES)
        num_violations = random.randint(0, 4)
        
        total_balance = Decimal('0.00')
        violations = []
        
        for v in range(num_violations):
            viol_id = f"viol_{i:03d}_{v+1:02d}"
            original = Decimal(str(random.choice([25, 50, 75, 100, 150, 200])))
            late_fee = Decimal(str(random.choice([0, 25, 50, 75])))
            amount = original + late_fee
            total_balance += amount
            
            viol_date = (datetime.now() - timedelta(days=random.randint(10, 90))).strftime('%Y-%m-%d')
            due_date = (datetime.strptime(viol_date, '%Y-%m-%d') + timedelta(days=30)).strftime('%Y-%m-%d')
            
            violations.append({
                'PK': f'CLIENT#CLIENT_001#VIOL#{viol_id}',
                'SK': 'DETAILS',
                'violationId': viol_id,
                'clientId': 'CLIENT_001',
                'customerId': cust_id,
                'citationNumber': f'CIT-2024-{100000+i*10+v}',
                'violationType': random.choice(VIOLATION_TYPES),
                'amount': amount,
                'originalAmount': original,
                'lateFees': late_fee,
                'violationDate': viol_date,
                'dueDate': due_date,
                'location': {'address': f'{random.randint(100,999)} Main St', 'city': city, 'state': state},
                'vehicle': {'licensePlate': plate, 'state': state},
                'status': random.choice(['OPEN', 'OPEN', 'OPEN', 'PAID']),
                'isPayable': True,
                'isDisputable': True,
                'hasActiveDispute': False,
                'paymentHistory': [],
                'createdAt': timestamp,
                'updatedAt': timestamp,
                'GSI1PK': f'CLIENT#CLIENT_001#CIT#CIT-2024-{100000+i*10+v}',
                'GSI1SK': f'VIOL#{viol_id}',
                'GSI2PK': f'CLIENT#CLIENT_001#CUST#{cust_id}',
                'GSI2SK': f'VIOL#{viol_date}#{viol_id}'
            })
        
        zipcode = f'{random.randint(10000,99999)}'
        
        customer = {
            'PK': f'CLIENT#CLIENT_001#CUST#{cust_id}',
            'SK': 'PROFILE',
            'customerId': cust_id,
            'clientId': 'CLIENT_001',
            'customerName': f'Customer {i}',
            'email': f'customer{i}@email.com',
            'phone': f'+1-555-{random.randint(100,999)}-{random.randint(1000,9999)}',
            'address': {'street': f'{random.randint(100,999)} Oak Ave', 'city': city, 'state': state, 'zipCode': zipcode},
            'accountNumber': f'ACC-{100000+i}',
            'accountStatus': 'ACTIVE',
            'totalBalance': total_balance,
            'vehicles': [{'licensePlate': plate, 'state': state, 'make': make, 'model': model}],
            'createdAt': timestamp,
            'updatedAt': timestamp,
            'GSI1PK': f'CLIENT#CLIENT_001#PLATE#{plate}#{state}',
            'GSI1SK': f'CUST#{cust_id}',
            'GSI2PK': f'CLIENT#CLIENT_001#ACCT#ACC-{100000+i}',
            'GSI2SK': f'ZIP#{zipcode}'
        }
        
        customers_table.put_item(Item=clean_none(customer))
        print(f"  {i}. {customer['customerName']} - {plate} ({state}) - ${total_balance} - {num_violations} violations")
        
        for viol in violations:
            violations_table.put_item(Item=clean_none(viol))
    
    print(f"\n✅ 25 customers seeded successfully!")


if __name__ == '__main__':
    seed_data()