#!/bin/bash
set -euo pipefail

# ============================================================
# update-lambda-code.sh
# Zips local lambda source and updates deployed functions.
# Preserves existing environment variables.
# Validates and fixes handlers per lambda-handlers.md manifest.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}"
source "${PROJECT_ROOT}/env.sh"

REGION="${REGION:?ERROR: REGION not set in env.sh}"
ENVIRONMENT="${ENVIRONMENT:?ERROR: ENVIRONMENT not set in env.sh}"
LAMBDAS_DIR="${PROJECT_ROOT}/lambdas"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# Detect Python
PY=""
for candidate in python3 python; do
  if command -v "$candidate" &>/dev/null; then
    PY=$(command -v "$candidate")
    break
  fi
done
[ -z "$PY" ] && echo "ERROR: Python not found" && exit 1

# Cross-platform file:// URI helper
file_uri() {
  local path="$1"
  if command -v cygpath &>/dev/null; then
    echo "fileb://$(cygpath -w "$path")"
  else
    echo "fileb://$path"
  fi
}

# Cross-platform zip: uses Python zipfile so 'zip' binary is not required
make_zip() {
  local src_dir="$1"
  local out_zip="$2"
  local _f
  _f=$(mktemp "${TMPDIR:-/tmp}/mkzip_XXXXXX")
  mv "$_f" "${_f}.py"
  _f="${_f}.py"
  cat > "$_f" << 'PYEOF'
import zipfile, os, sys
src = sys.argv[1]
out = sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(src):
        for f in files:
            abs_path = os.path.join(root, f)
            arc_name = os.path.relpath(abs_path, src)
            zf.write(abs_path, arc_name)
PYEOF
  "$PY" "$_f" "$src_dir" "$out_zip"
  local rc=$?
  rm -f "$_f"
  return $rc
}

# ============================================================
# Lambda mapping: FUNCTION_NAME|HANDLER|LOCAL_SOURCE_DIR
# ============================================================
MAPPINGS=(
  # Tool lambdas (7)
  "anycompany-ivr-lookup-by-plate-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/lookup-by-plate"
  "anycompany-ivr-lookup-by-citation-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/lookup-by-citation"
  "anycompany-ivr-lookup-by-account-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/lookup-by-account"
  "anycompany-ivr-get-balance-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/get-balance"
  "anycompany-ivr-get-violation-details-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/get-violation-details"
  "anycompany-ivr-submit-dispute-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/submit-dispute"
  "anycompany-ivr-check-dispute-status-${ENVIRONMENT}|index.lambda_handler|tool-lambdas/check-dispute-status"
  # Fulfillment (1)
  "anycompany-ivr-${ENVIRONMENT}-QinConnectDialogHook|lambda_function.lambda_handler|fulfillment/qinconnect-dialog-hook"
  # Payment lambdas (6)
  "anycompany-ivr-build-payment-cart-${ENVIRONMENT}|build_payment_cart.lambda_handler|payment/build-payment-cart"
  "anycompany-ivr-initiate-payment-${ENVIRONMENT}|initiate_payment.lambda_handler|payment/initiate-payment"
  "ivr-${ENVIRONMENT}-SeedPaymentSession|seed_session.lambda_handler|payment/seed-payment-session"
  "ivr-${ENVIRONMENT}-PaymentProcessing|index.lambda_handler|payment/payment-processing"
  "ivr-${ENVIRONMENT}-UpdateViolationBalance|index.lambda_handler|payment/update-violation-balance"
  "ivr-${ENVIRONMENT}-SaveAndRestoreSession|index.lambda_handler|payment/save-and-restore-session"
  # Connect lambdas (2)
  "anycompany-ivr-${ENVIRONMENT}-getCallAttributes|index.lambda_handler|connect/get-call-attributes"
  "ConnectAssistantUpdateSessionDataNew|index.handler|connect/connect-assistant-update-session"
)

echo "============================================"
echo "Updating Lambda Functions from Local Source"
echo "============================================"
echo "  Region:      ${REGION}"
echo "  Environment: ${ENVIRONMENT}"
echo "  Source:      ${LAMBDAS_DIR}"
echo "  Functions:   ${#MAPPINGS[@]}"
echo ""

ERRORS=()

# ============================================================
# Step 1: Zip and upload code
# ============================================================
echo ">>> Step 1: Packaging and uploading code..."
echo "------------------------------------------------------------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r FUNC_NAME HANDLER SOURCE_DIR <<< "${MAPPING}"
  LOCAL_PATH="${LAMBDAS_DIR}/${SOURCE_DIR}"

  if [ ! -d "${LOCAL_PATH}" ]; then
    echo "  ❌ ${FUNC_NAME} — source not found: ${SOURCE_DIR}"
    ERRORS+=("${FUNC_NAME}: source dir missing")
    continue
  fi

  # Check function exists in AWS
  if ! aws lambda get-function --function-name "${FUNC_NAME}" --region "${REGION}" > /dev/null 2>&1; then
    echo "  ❌ ${FUNC_NAME} — not found in AWS, skipping"
    ERRORS+=("${FUNC_NAME}: not deployed")
    continue
  fi

  ZIP_FILE="${TMP_DIR}/${FUNC_NAME}.zip"

  # Install dependencies if requirements.txt exists (Python)
  if [ -f "${LOCAL_PATH}/requirements.txt" ] && [ -s "${LOCAL_PATH}/requirements.txt" ]; then
    PACKAGE_DIR="${TMP_DIR}/pkg-${FUNC_NAME}"
    mkdir -p "${PACKAGE_DIR}"
    pip3 install -q -r "${LOCAL_PATH}/requirements.txt" -t "${PACKAGE_DIR}" 2>/dev/null
    cp "${LOCAL_PATH}"/*.py "${PACKAGE_DIR}/" 2>/dev/null || true
    make_zip "${PACKAGE_DIR}" "${ZIP_FILE}"
  # Install dependencies if package.json exists (Node.js)
  elif [ -f "${LOCAL_PATH}/package.json" ]; then
    PACKAGE_DIR="${TMP_DIR}/pkg-${FUNC_NAME}"
    mkdir -p "${PACKAGE_DIR}"
    cp -r "${LOCAL_PATH}/"* "${PACKAGE_DIR}/"
    (cd "${PACKAGE_DIR}" && npm install --production --silent 2>/dev/null)
    make_zip "${PACKAGE_DIR}" "${ZIP_FILE}"
  else
    make_zip "${LOCAL_PATH}" "${ZIP_FILE}"
  fi

  echo -n "  ${FUNC_NAME}..."

  aws lambda update-function-code \
    --function-name "${FUNC_NAME}" \
    --zip-file "$(file_uri "${ZIP_FILE}")" \
    --region "${REGION}" > /dev/null

  aws lambda wait function-updated \
    --function-name "${FUNC_NAME}" \
    --region "${REGION}" 2>/dev/null || sleep 5

  echo " ✅"
done

# ============================================================
# Step 2: Validate and fix handlers
# ============================================================
echo ""
echo ">>> Step 2: Validating handlers..."
echo "------------------------------------------------------------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r FUNC_NAME HANDLER _ <<< "${MAPPING}"

  CURRENT=$(aws lambda get-function-configuration \
    --function-name "${FUNC_NAME}" \
    --region "${REGION}" \
    --query "Handler" \
    --output text 2>/dev/null) || continue

  if [ "${CURRENT}" = "${HANDLER}" ]; then
    echo "  ${FUNC_NAME}: ✅ ${HANDLER}"
  else
    echo "  ${FUNC_NAME}: ${CURRENT} → ${HANDLER}"

    aws lambda wait function-updated \
      --function-name "${FUNC_NAME}" \
      --region "${REGION}" 2>/dev/null || sleep 3

    aws lambda update-function-configuration \
      --function-name "${FUNC_NAME}" \
      --handler "${HANDLER}" \
      --region "${REGION}" > /dev/null

    aws lambda wait function-updated \
      --function-name "${FUNC_NAME}" \
      --region "${REGION}" 2>/dev/null || sleep 3

    echo "    ✅ Fixed"
  fi
done

# ============================================================
# Step 3: Verify environment variables are intact
# ============================================================
echo ""
echo ">>> Step 3: Verifying environment variables..."
echo "------------------------------------------------------------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r FUNC_NAME _ _ <<< "${MAPPING}"

  ENV_VARS=$(aws lambda get-function-configuration \
    --function-name "${FUNC_NAME}" \
    --region "${REGION}" \
    --query "Environment.Variables" \
    --output json 2>/dev/null) || continue

  if [ "${ENV_VARS}" = "null" ] || [ -z "${ENV_VARS}" ]; then
    echo "  ${FUNC_NAME}: ⚠️  No env vars set"
  else
    VAR_COUNT=$(echo "${ENV_VARS}" | "$PY" -c "import sys,json; print(len(json.load(sys.stdin)))")
    echo "  ${FUNC_NAME}: ✅ ${VAR_COUNT} env var(s)"
  fi
done

# ============================================================
# Step 4: Final summary
# ============================================================
echo ""
echo "============================================"
echo "Final Verification"
echo "============================================"
echo ""

printf "%-55s %-40s %s\n" "FUNCTION" "HANDLER" "STATUS"
printf "%-55s %-40s %s\n" \
  "$(printf '%0.s-' {1..55})" "$(printf '%0.s-' {1..40})" "------"

for MAPPING in "${MAPPINGS[@]}"; do
  IFS='|' read -r FUNC_NAME EXPECTED _ <<< "${MAPPING}"

  ACTUAL=$(aws lambda get-function-configuration \
    --function-name "${FUNC_NAME}" \
    --region "${REGION}" \
    --query "Handler" \
    --output text 2>/dev/null) || { printf "%-55s ❌ NOT FOUND\n" "${FUNC_NAME}"; continue; }

  if [ "${ACTUAL}" = "${EXPECTED}" ]; then
    printf "%-55s %-40s ✅\n" "${FUNC_NAME}" "${ACTUAL}"
  else
    printf "%-55s %-40s ❌ expected: %s\n" "${FUNC_NAME}" "${ACTUAL}" "${EXPECTED}"
  fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "⚠️  Warnings:"
  for ERR in "${ERRORS[@]}"; do
    echo "  - ${ERR}"
  done
fi

echo ""
echo "✅ Done! ${#MAPPINGS[@]} Lambda functions processed."
echo ""
echo "Note: Environment variables were preserved from deployed functions."
echo "To update env vars, use the CloudFormation stacks or update-function-configuration."
