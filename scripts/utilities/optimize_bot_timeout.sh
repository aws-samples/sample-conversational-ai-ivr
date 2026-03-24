#!/bin/bash
# optimize-bot-timeouts.sh
# Sets speech timeout optimizations on ParkAndTollBot

ACCOUNT_ID="123456789012"
REGION="us-east-1"
BOT_ID="PARK_BOT_ID_PLACEHOLDER"

# First, get the bot alias ID for 'live'
echo "=== Getting bot alias ID ==="
ALIAS_INFO=$(aws lexv2-models list-bot-aliases \
    --bot-id "$BOT_ID" \
    --region "$REGION" \
    --query "botAliasSummaries[?botAliasName=='live']" \
    --output json)

echo "$ALIAS_INFO" | python3 -m json.tool

ALIAS_ID=$(echo "$ALIAS_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['botAliasId'])")
echo "Bot Alias ID: $ALIAS_ID"

# Get the current bot alias configuration
echo ""
echo "=== Current bot alias configuration ==="
aws lexv2-models describe-bot-alias \
    --bot-id "$BOT_ID" \
    --bot-alias-id "$ALIAS_ID" \
    --region "$REGION" \
    --output json > /tmp/current-alias-config.json

echo "Current config saved to /tmp/current-alias-config.json"
cat /tmp/current-alias-config.json | python3 -m json.tool