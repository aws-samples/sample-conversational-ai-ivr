#!/bin/bash
# fix-agentcore-gateway-permissions.sh

ROLE_NAME="anycompany-ivr-AgentCoreGatewa-AgentCoreGatewayRole-A0CdrjubpB1O"
ACCOUNT_ID="123456789012"
REGION="us-east-1"

echo "============================================"
echo "  Fix AgentCore Gateway Permissions"
echo "============================================"

# ============================================================
# Policy 1: Workload Identity + API Key + Secrets
# ============================================================
cat > /tmp/agentcore-identity-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "GetWorkloadAccessToken",
            "Effect": "Allow",
            "Action": [
                "bedrock-agentcore:GetWorkloadAccessToken"
            ],
            "Resource": [
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:workload-identity-directory/default",
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:workload-identity-directory/default/workload-identity/c001-ivr-mcp-gw-*"
            ]
        },
        {
            "Sid": "GetResourceApiKey",
            "Effect": "Allow",
            "Action": [
                "bedrock-agentcore:GetResourceApiKey"
            ],
            "Resource": [
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:token-vault/default",
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:token-vault/default/apikeycredentialprovider/anycompany-ivr-demo-apigw-api-key-provider",
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:workload-identity-directory/default",
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:workload-identity-directory/default/workload-identity/c001-ivr-mcp-gw-*"
            ]
        },
        {
            "Sid": "GetSecretValue",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": [
                "arn:aws:secretsmanager:us-east-1:123456789012:secret:bedrock-agentcore-identity!default/apikey/anycompany-ivr-demo-apigw-api-key-provider-*"
            ]
        }
    ]
}
EOF

echo ""
echo "Creating Policy 1: AgentCoreIdentityAndApiKeyAccess..."
POLICY1_ARN=$(aws iam create-policy \
  --policy-name "AgentCoreIdentityAndApiKeyAccess" \
  --policy-document file:///tmp/agentcore-identity-policy.json \
  --query 'Policy.Arn' \
  --output text \
  --region $REGION 2>&1)

if echo "$POLICY1_ARN" | grep -q "EntityAlreadyExists"; then
  echo "  Policy already exists, fetching ARN..."
  POLICY1_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AgentCoreIdentityAndApiKeyAccess"
else
  echo "  ✅ Created: $POLICY1_ARN"
fi

# ============================================================
# Policy 2: Gateway Access
# ============================================================
cat > /tmp/agentcore-gateway-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "GetGateway",
            "Effect": "Allow",
            "Action": [
                "bedrock-agentcore:GetGateway"
            ],
            "Resource": [
                "arn:aws:bedrock-agentcore:us-east-1:123456789012:gateway/c001-ivr-mcp-gw-*"
            ]
        }
    ]
}
EOF

echo ""
echo "Creating Policy 2: AgentCoreGatewayAccess..."
POLICY2_ARN=$(aws iam create-policy \
  --policy-name "AgentCoreGatewayAccess" \
  --policy-document file:///tmp/agentcore-gateway-policy.json \
  --query 'Policy.Arn' \
  --output text \
  --region $REGION 2>&1)

if echo "$POLICY2_ARN" | grep -q "EntityAlreadyExists"; then
  echo "  Policy already exists, fetching ARN..."
  POLICY2_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AgentCoreGatewayAccess"
else
  echo "  ✅ Created: $POLICY2_ARN"
fi

# ============================================================
# Attach both policies to the role
# ============================================================
echo ""
echo "Attaching policies to role: $ROLE_NAME"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY1_ARN"
echo "  ✅ Policy 1 (Identity + API Key) attached"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY2_ARN"
echo "  ✅ Policy 2 (Gateway Access) attached"

# ============================================================
# Verify
# ============================================================
echo ""
echo "============================================"
echo "  Verification"
echo "============================================"

echo ""
echo "=== Attached Policies ==="
aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --output table

echo ""
echo "=== Policy 1 Document ==="
POLICY1_VERSION=$(aws iam get-policy --policy-arn "$POLICY1_ARN" --query 'Policy.DefaultVersionId' --output text)
aws iam get-policy-version --policy-arn "$POLICY1_ARN" --version-id "$POLICY1_VERSION" --output json

echo ""
echo "=== Policy 2 Document ==="
POLICY2_VERSION=$(aws iam get-policy --policy-arn "$POLICY2_ARN" --query 'Policy.DefaultVersionId' --output text)
aws iam get-policy-version --policy-arn "$POLICY2_ARN" --version-id "$POLICY2_VERSION" --output json

echo ""
echo "============================================"
echo "  Done! Wait 30 seconds then test a call."
echo "============================================"