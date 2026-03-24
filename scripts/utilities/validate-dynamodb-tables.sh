#!/bin/bash
# validate-dynamodb-tables.sh

REGION="us-east-1"

for TABLE in anycompany-ivr-customers-dev anycompany-ivr-violations-dev anycompany-ivr-disputes-dev; do
    echo "=== $TABLE ==="
    
    python3 << PYEOF
import json, boto3

client = boto3.client('dynamodb', region_name='$REGION')

try:
    resp = client.describe_table(TableName='$TABLE')
    t = resp['Table']
    
    print(f"Table: {t['TableName']}")
    print(f"Billing: {t.get('BillingModeSummary', {}).get('BillingMode', 'UNKNOWN')}")
    
    print(f"\nKey Schema:")
    for k in t['KeySchema']:
        print(f"  {k['AttributeName']} ({k['KeyType']})")
    
    print(f"\nAttribute Definitions:")
    for a in sorted(t['AttributeDefinitions'], key=lambda x: x['AttributeName']):
        print(f"  {a['AttributeName']} ({a['AttributeType']})")
    
    print(f"\nGSIs:")
    for g in t.get('GlobalSecondaryIndexes', []):
        print(f"  {g['IndexName']}:")
        for k in g['KeySchema']:
            print(f"    {k['AttributeName']} ({k['KeyType']})")
        print(f"    Projection: {g['Projection']['ProjectionType']}")
    
    sse = t.get('SSEDescription', {})
    print(f"\nSSE: {sse.get('Status', 'UNKNOWN')} ({sse.get('SSEType', 'N/A')})")
    
    # PITR
    try:
        pitr = client.describe_continuous_backups(TableName='$TABLE')
        status = pitr['ContinuousBackupsDescription']['PointInTimeRecoveryDescription']['PointInTimeRecoveryStatus']
        print(f"PITR: {status}")
    except:
        print("PITR: UNKNOWN")
    
    # TTL
    try:
        ttl = client.describe_time_to_live(TableName='$TABLE')
        print(f"TTL: {ttl['TimeToLiveDescription']['TimeToLiveStatus']} ({ttl['TimeToLiveDescription'].get('AttributeName', 'N/A')})")
    except:
        print("TTL: UNKNOWN")

except Exception as e:
    print(f"ERROR: {e}")

PYEOF
    echo ""
done