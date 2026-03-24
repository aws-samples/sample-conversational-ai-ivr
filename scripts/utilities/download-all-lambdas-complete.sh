#!/bin/bash
# download-all-lambdas-complete.sh

REGION="us-east-1"
OUTPUT_DIR="$HOME/anycompany-ivr-lambdas"
OUTPUT_DIR="./lambda-code-export-03232026"
mkdir -p "$OUTPUT_DIR"

LAMBDAS=(
    # Contact Flow lambdas (invoked by Connect)
    "anycompany-ivr-dev-getCallAttributes"
    "ConnectAssistantUpdateSessionDataNew"
    "ivr-dev-SaveAndRestoreSession"
    "ivr-dev-SeedPaymentSession"
    "ivr-dev-UpdateViolationBalance"
    
    # Lex Fulfillment lambdas (invoked by Lex bots)
    "anycompany-ivr-dev-QinConnectDialogHook"
    "ivr-dev-PaymentProcessing"
    
    # API Gateway / AgentCore Tool lambdas (invoked by AgentCore Gateway)
    "anycompany-ivr-build-payment-cart-dev"
    "anycompany-ivr-initiate-payment-dev"
    "anycompany-ivr-lookup-by-plate-dev"
    "anycompany-ivr-lookup-by-citation-dev"
    "anycompany-ivr-lookup-by-account-dev"
    "anycompany-ivr-get-balance-dev"
    "anycompany-ivr-get-violation-details-dev"
    "anycompany-ivr-submit-dispute-dev"
    "anycompany-ivr-check-dispute-status-dev"
)

echo "Downloading ${#LAMBDAS[@]} Lambda functions..."
echo ""

# Create manifest
cat > "$OUTPUT_DIR/MANIFEST.md" << EOF
# Lambda Functions — anycompany-ivr
# Account: 123456789012 | Region: us-east-1
# Downloaded: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

| Function | Handler | Source File | Runtime | Memory | Timeout |
|----------|---------|-------------|---------|--------|---------|
EOF

for FUNC in "${LAMBDAS[@]}"; do
    echo "=== $FUNC ==="
    
    FUNC_DIR="$OUTPUT_DIR/$FUNC"
    mkdir -p "$FUNC_DIR/src" "$FUNC_DIR/iam"
    
    # Get configuration
    CONFIG=$(aws lambda get-function-configuration \
        --function-name "$FUNC" \
        --region "$REGION" \
        --output json 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "  ❌ NOT FOUND"
        echo ""
        continue
    fi
    
    echo "$CONFIG" > "$FUNC_DIR/config.json"
    
    HANDLER=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['Handler'])")
    RUNTIME=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['Runtime'])")
    MEMORY=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['MemorySize'])")
    TIMEOUT=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['Timeout'])")
    ROLE_ARN=$(echo "$CONFIG" | python3 -c "import json,sys; print(json.load(sys.stdin)['Role'])")
    ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
    ENV_VARS=$(echo "$CONFIG" | python3 -c "import json,sys; d=json.load(sys.stdin).get('Environment',{}).get('Variables',{}); print(json.dumps(d, indent=2))")
    
    # Derive expected source file
    MODULE=$(echo "$HANDLER" | cut -d'.' -f1)
    if echo "$RUNTIME" | grep -q "nodejs"; then
        SOURCE_FILE="${MODULE}.js"
    else
        SOURCE_FILE="${MODULE}.py"
    fi
    
    echo "  Handler:  $HANDLER → $SOURCE_FILE"
    echo "  Runtime:  $RUNTIME | Memory: ${MEMORY}MB | Timeout: ${TIMEOUT}s"
    echo "  Role:     $ROLE_NAME"
    echo "  Env vars: $ENV_VARS"
    
    # Download code
    URL=$(aws lambda get-function \
        --function-name "$FUNC" \
        --region "$REGION" \
        --query "Code.Location" --output text)
    
    curl -s -o "$FUNC_DIR/code.zip" "$URL"
    unzip -o -q "$FUNC_DIR/code.zip" -d "$FUNC_DIR/src"
    rm "$FUNC_DIR/code.zip"
    
    # Verify handler file
    if [ -f "$FUNC_DIR/src/$SOURCE_FILE" ]; then
        echo "  ✅ Handler file verified: $SOURCE_FILE"
    else
        echo "  ⚠️  WARNING: $SOURCE_FILE not found! Actual files:"
        find "$FUNC_DIR/src" -maxdepth 1 $ -name "*.py" -o -name "*.js" $ -exec basename {} \; | sed 's/^/       /'
    fi
    
    # List all source files
    echo "  Files:"
    find "$FUNC_DIR/src" -maxdepth 1 $ -name "*.py" -o -name "*.js" -o -name "*.json" -o -name "requirements.txt" $ -exec basename {} \; | sort | sed 's/^/    /'
    
    # Resource policy
    aws lambda get-policy \
        --function-name "$FUNC" \
        --region "$REGION" \
        --query "Policy" --output text 2>/dev/null | python3 -m json.tool > "$FUNC_DIR/resource-policy.json" 2>/dev/null
    
    if [ ! -s "$FUNC_DIR/resource-policy.json" ]; then
        echo '{"Statement":[]}' > "$FUNC_DIR/resource-policy.json"
    fi
    
    # IAM: trust policy
    aws iam get-role \
        --role-name "$ROLE_NAME" \
        --query "Role.AssumeRolePolicyDocument" \
        --output json > "$FUNC_DIR/iam/trust-policy.json" 2>/dev/null
    
    # IAM: inline policies
    for POLICY in $(aws iam list-role-policies --role-name "$ROLE_NAME" \
        --query "PolicyNames[]" --output text 2>/dev/null); do
        aws iam get-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name "$POLICY" \
            --output json > "$FUNC_DIR/iam/inline-${POLICY}.json"
        echo "  IAM inline: $POLICY"
    done
    
    # IAM: managed policies
    aws iam list-attached-role-policies \
        --role-name "$ROLE_NAME" \
        --output json > "$FUNC_DIR/iam/managed-policies.json" 2>/dev/null
    
    # Append to manifest
    echo "| \`$FUNC\` | \`$HANDLER\` | \`$SOURCE_FILE\` | $RUNTIME | ${MEMORY}MB | ${TIMEOUT}s |" >> "$OUTPUT_DIR/MANIFEST.md"
    
    echo ""
done

# Summary
echo "============================================"
echo "Download complete: $OUTPUT_DIR"
echo "============================================"
echo ""
cat "$OUTPUT_DIR/MANIFEST.md"
echo ""

# Handler verification summary
echo ""
echo "=== Handler Verification ==="
PASS=0
FAIL=0
for FUNC_DIR in "$OUTPUT_DIR"/*/; do
    [ ! -f "$FUNC_DIR/config.json" ] && continue
    FUNC=$(basename "$FUNC_DIR")
    HANDLER=$(python3 -c "import json; print(json.load(open('${FUNC_DIR}config.json'))['Handler'])")
    RUNTIME=$(python3 -c "import json; print(json.load(open('${FUNC_DIR}config.json'))['Runtime'])")
    MODULE=$(echo "$HANDLER" | cut -d'.' -f1)
    if echo "$RUNTIME" | grep -q "nodejs"; then
        EXPECTED="${MODULE}.js"
    else
        EXPECTED="${MODULE}.py"
    fi
    
    if [ -f "${FUNC_DIR}src/$EXPECTED" ]; then
        echo "  ✅ $FUNC → $HANDLER → $EXPECTED"
        PASS=$((PASS+1))
    else
        ACTUAL=$(find "${FUNC_DIR}src" -maxdepth 1 $ -name "*.py" -o -name "*.js" $ -exec basename {} \; | tr '\n' ', ')
        echo "  ❌ $FUNC → $HANDLER → expected $EXPECTED | found: $ACTUAL"
        FAIL=$((FAIL+1))
    fi
done
echo ""
echo "Results: $PASS passed, $FAIL failed"
