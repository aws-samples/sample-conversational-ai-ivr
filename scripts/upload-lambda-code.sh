#!/bin/bash
set -euo pipefail

REGION="us-east-1"
CODE_DIR="./lambda-code-export"

NEW_CONNECT_INSTANCE_ID="CONNECT_INSTANCE_ID_PLACEHOLDER"
NEW_AI_ASSISTANT_ID="WISDOM_ASSISTANT_ID_PLACEHOLDER"

# TARGET_NAME|CORRECT_HANDLER
MAPPINGS=(
  "ConnectAssistantUpdateSessionDataNew|index.handler"
  "anycompany-ivr-dev-getCallAttributes|index.lambda_handler"
  "ivr-dev-SeedPaymentSession|seed_session.lambda_handler"
  "ivr-dev-SaveAndRestoreSession|index.lambda_handler"
  "ivr-dev-UpdateViolationBalance|index.lambda_handler"
  "ivr-dev-PaymentProcessing|index.lambda_handler"
  "anycompany-ivr-dev-QinConnectDialogHook|lambda_function.lambda_handler"
  "anycompany-ivr-initiate-payment-dev|initiate_payment.lambda_handler"
  "anycompany-ivr-build-payment-cart-dev|build_payment_cart.lambda_handler"
)

echo "============================================"
echo "Uploading Lambda code to NEW environment"
echo "Source: ${CODE_DIR}"
echo "============================================"

# Verify zip files exist
if [ ! -d "${CODE_DIR}" ]; then
  echo "❌ ${CODE_DIR} not found. Copy from working env first."
  exit 1
fi

echo ""
echo "Found zips:"
ls -lh "${CODE_DIR}"/*.zip
echo ""

# ============================================================
# Step 1: Upload code
# ============================================================
echo "Step 1: Uploading code..."
echo "------------------------------------------------------------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r TARGET_FUNC HANDLER <<< "${MAPPING}"
  ZIP_FILE="${CODE_DIR}/${TARGET_FUNC}.zip"

  if [ ! -f "${ZIP_FILE}" ]; then
    echo "  ⚠️  ${TARGET_FUNC} — zip not found, skipping"
    continue
  fi

  echo "  Uploading: ${TARGET_FUNC}..."

  aws lambda update-function-code \
    --function-name "${TARGET_FUNC}" \
    --zip-file "fileb://${ZIP_FILE}" \
    --region "${REGION}" > /dev/null

  aws lambda wait function-updated \
    --function-name "${TARGET_FUNC}" \
    --region "${REGION}" 2>/dev/null || sleep 5

  echo "    ✅ Code uploaded"
done

# ============================================================
# Step 2: Fix handlers
# ============================================================
echo ""
echo "Step 2: Fixing handlers..."
echo "------------------------------------------------------------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r TARGET_FUNC HANDLER <<< "${MAPPING}"

  CURRENT=$(aws lambda get-function-configuration \
    --function-name "${TARGET_FUNC}" \
    --region "${REGION}" \
    --query "Handler" \
    --output text 2>/dev/null) || continue

  if [ "${CURRENT}" != "${HANDLER}" ]; then
    echo "  ${TARGET_FUNC}: ${CURRENT} → ${HANDLER}"

    aws lambda wait function-updated \
      --function-name "${TARGET_FUNC}" \
      --region "${REGION}" 2>/dev/null || sleep 3

    aws lambda update-function-configuration \
      --function-name "${TARGET_FUNC}" \
      --handler "${HANDLER}" \
      --region "${REGION}" > /dev/null

    aws lambda wait function-updated \
      --function-name "${TARGET_FUNC}" \
      --region "${REGION}" 2>/dev/null || sleep 3

    echo "    ✅ Fixed"
  else
    echo "  ${TARGET_FUNC}: ✅ OK (${HANDLER})"
  fi
done

# ============================================================
# Step 3: Update environment variables
# ============================================================
echo ""
echo "Step 3: Updating environment variables..."
echo "------------------------------------------------------------"

update_env() {
  local FUNC=$1; local ENV_JSON=$2
  aws lambda wait function-updated \
    --function-name "${FUNC}" --region "${REGION}" 2>/dev/null || sleep 3
  aws lambda update-function-configuration \
    --function-name "${FUNC}" \
    --environment "${ENV_JSON}" \
    --region "${REGION}" > /dev/null
  echo "    ✅ Updated"
}

echo "  ConnectAssistantUpdateSessionDataNew..."
update_env "ConnectAssistantUpdateSessionDataNew" '{
  "Variables": {
    "AI_ASSISTANT_ID": "'"${NEW_AI_ASSISTANT_ID}"'",
    "CONNECT_INSTANCE_ID": "'"${NEW_CONNECT_INSTANCE_ID}"'"
  }
}'

echo "  anycompany-ivr-dev-getCallAttributes..."
update_env "anycompany-ivr-dev-getCallAttributes" '{
  "Variables": {
    "CLIENT_CONFIG_TABLE": "anycompany-ivr-client-config-dev",
    "PHONE_NUMBER_INDEX": "PhoneNumber-Index"
  }
}'

echo "  ivr-dev-SeedPaymentSession..."
echo "    ℹ️  No env vars needed"

echo "  ivr-dev-SaveAndRestoreSession..."
update_env "ivr-dev-SaveAndRestoreSession" '{
  "Variables": {
    "ENVIRONMENT": "dev",
    "SESSION_TABLE_NAME": "IVRSessionContext-dev"
  }
}'

echo "  ivr-dev-UpdateViolationBalance..."
update_env "ivr-dev-UpdateViolationBalance" '{
  "Variables": {
    "ENVIRONMENT": "dev",
    "VIOLATION_API_URL": "MOCK_MODE",
    "LOG_LEVEL": "INFO",
    "VIOLATION_API_KEY_PARAM": "/ivr/payment/dev/violation-api-key"
  }
}'

echo "  ivr-dev-PaymentProcessing..."
update_env "ivr-dev-PaymentProcessing" '{
  "Variables": {
    "PAYMENT_GATEWAY_URL_PARAM": "/ivr/payment/dev/gateway-url",
    "ENVIRONMENT": "dev",
    "PAYMENT_API_KEY_PARAM": "/ivr/payment/dev/api-key"
  }
}'

echo "  anycompany-ivr-dev-QinConnectDialogHook..."
update_env "anycompany-ivr-dev-QinConnectDialogHook" '{
  "Variables": {
    "SESSION_TABLE_NAME": "IVRSessionContext-dev",
    "LOG_LEVEL": "INFO"
  }
}'

echo "  anycompany-ivr-initiate-payment-dev..."
update_env "anycompany-ivr-initiate-payment-dev" '{
  "Variables": {
    "CONNECT_INSTANCE_ID": "'"${NEW_CONNECT_INSTANCE_ID}"'",
    "SESSION_TABLE_NAME": "IVRSessionContext-dev"
  }
}'

echo "  anycompany-ivr-build-payment-cart-dev..."
update_env "anycompany-ivr-build-payment-cart-dev" '{
  "Variables": {
    "CART_TTL_HOURS": "2",
    "SESSION_TABLE_NAME": "IVRSessionContext-dev"
  }
}'

# ============================================================
# Step 4: Verify
# ============================================================
echo ""
echo "============================================"
echo "Step 4: Final verification"
echo "============================================"
echo ""

printf "%-50s %-45s %s\n" "FUNCTION" "HANDLER" "OK"
printf "%-50s %-45s %s\n" \
  "$(printf '%0.s-' {1..50})" "$(printf '%0.s-' {1..45})" "---"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r TARGET_FUNC EXPECTED <<< "${MAPPING}"

  ACTUAL=$(aws lambda get-function-configuration \
    --function-name "${TARGET_FUNC}" \
    --region "${REGION}" \
    --query "Handler" \
    --output text 2>/dev/null) || { printf "%-50s ❌ NOT FOUND\n" "${TARGET_FUNC}"; continue; }

  if [ "${ACTUAL}" = "${EXPECTED}" ]; then
    printf "%-50s %-45s ✅\n" "${TARGET_FUNC}" "${ACTUAL}"
  else
    printf "%-50s %-45s ❌ expected: %s\n" "${TARGET_FUNC}" "${ACTUAL}" "${EXPECTED}"
  fi
done

echo ""
echo "✅ All Lambda functions updated!"