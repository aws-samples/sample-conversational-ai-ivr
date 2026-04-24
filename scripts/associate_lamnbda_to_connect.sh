#!/bin/bash
set -euo pipefail

REGION="${REGION:?ERROR: export REGION before running (e.g., source env.sh)}"
CONNECT_INSTANCE_ID="${CONNECT_INSTANCE_ID:?ERROR: export CONNECT_INSTANCE_ID before running (e.g., source env.sh)}"

echo "============================================"
echo "Associating Lambdas with Connect Instance"
echo "============================================"

# All 5 Lambda function names
LAMBDA_FUNCTIONS=(
  "ConnectAssistantUpdateSessionDataNew"
  "anycompany-ivr-dev-getCallAttributes"
  "ivr-dev-SeedPaymentSession"
  "ivr-dev-SaveAndRestoreSession"
  "ivr-dev-UpdateViolationBalance"
)

echo ""
echo ">>> Resolving and associating Lambdas..."

for FUNC_NAME in "${LAMBDA_FUNCTIONS[@]}"; do
  # Resolve ARN
  LAMBDA_ARN=$(aws lambda get-function \
    --function-name "${FUNC_NAME}" \
    --region "${REGION}" \
    --query "Configuration.FunctionArn" \
    --output text 2>/dev/null) || true

  if [ -z "${LAMBDA_ARN}" ] || [ "${LAMBDA_ARN}" = "None" ]; then
    echo "  ❌ ${FUNC_NAME} — NOT FOUND"
    continue
  fi

  # Associate with Connect
  aws connect associate-lambda-function \
    --instance-id "${CONNECT_INSTANCE_ID}" \
    --function-arn "${LAMBDA_ARN}" \
    --region "${REGION}" 2>/dev/null \
    && echo "  ✅ ${FUNC_NAME}" \
    || echo "  ℹ️  ${FUNC_NAME} (already associated)"
done

# Verify
echo ""
echo ">>> All associated Lambdas:"
aws connect list-lambda-functions \
  --instance-id "${CONNECT_INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'LambdaFunctions[*]' \
  --output table

echo ""
echo "✅ Done!"