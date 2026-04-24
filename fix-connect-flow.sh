#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# fix-connect-flow.sh
# Replaces placeholder ARNs in a Connect contact flow JSON with real
# deployed resource ARNs.
#
# Usage:
#   ./fix-connect-flow.sh [path/to/flow.json]
#
# Mode 1 — Pre-import fix (input file provided):
#   Reads the local JSON file, replaces placeholders, writes the fixed file.
#   Use this BEFORE importing the flow into Connect.
#
# Mode 2 — Post-import fix (no input file):
#   Exports the flow from a deployed Connect instance, replaces placeholders,
#   writes the fixed file. You then import it manually.
#
# In BOTH modes the script does NOT publish the flow — it outputs the
# fixed file location and the steps to import/update it yourself.
#
# Reads REGION, ACCOUNT_ID, CONNECT_INSTANCE_ID from env.sh
###############################################################################

# ─── Source Environment ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.sh"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "  ❌ env.sh not found at: ${ENV_FILE}"
  echo "  Expected variables: REGION, ACCOUNT_ID, CONNECT_INSTANCE_ID"
  exit 1
fi

source "${ENV_FILE}"

# ─── Validate Required Variables ────────────────────────────────────────────
MISSING_VARS=()
[[ -z "${REGION:-}" ]]              && MISSING_VARS+=("REGION")
[[ -z "${ACCOUNT_ID:-}" ]]          && MISSING_VARS+=("ACCOUNT_ID")
[[ -z "${CONNECT_INSTANCE_ID:-}" ]] && MISSING_VARS+=("CONNECT_INSTANCE_ID")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
  echo "  ❌ Missing required variables in env.sh:"
  for var in "${MISSING_VARS[@]}"; do echo "     - ${var}"; done
  exit 1
fi

# ─── Configuration ──────────────────────────────────────────────────────────
INPUT_FILE="${1:-}"
FLOW_NAME="${FLOW_NAME:-Main Flow}"
PLACEHOLDER_ACCOUNT="${PLACEHOLDER_ACCOUNT:-123456789012}"
PARK_BOT_NAME="${PARK_BOT_NAME:-ParkAndTollBot}"
PARK_BOT_ALIAS_NAME="${PARK_BOT_ALIAS_NAME:-live}"

WORK_DIR="${SCRIPT_DIR}/flow-updates"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "${WORK_DIR}"

# ─── jq helper: use jq if available, else fall back to Python ──────────────
if command -v jq &>/dev/null; then
  jq_cmd() { jq "$@"; }
else
  jq_cmd() {
    local filter="$1"; shift
    "$PY" -c "
import sys, json
data = json.load(open('$1') if len(sys.argv) > 1 and '$1' != '-' else sys.stdin)
if '$filter' == '.':
    print(json.dumps(data, indent=2))
elif '$filter' == 'length':
    print(len(data))
else:
    print(data)
" 2>/dev/null || cat "$1"
  }
fi

# ─── Detect Python (needed for jq fallback) ──────────────────────────────────
PY=""
for candidate in python3 python; do
  if command -v "$candidate" &>/dev/null; then
    PY=$(command -v "$candidate")
    break
  fi
done
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}  ✅ $1${NC}"; }
warn()   { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
err()    { echo -e "${RED}  ❌ $1${NC}"; }
info()   { echo -e "${CYAN}  ℹ️  $1${NC}"; }
header() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  $1${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ─── Banner ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Contact Flow ARN Fix                               ║${NC}"
echo -e "${BOLD}║   Replace placeholder ARNs with real deployed ARNs   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Environment (from env.sh):"
echo "    Region:              ${REGION}"
echo "    Account ID:          ${ACCOUNT_ID}"
echo "    Placeholder Account: ${PLACEHOLDER_ACCOUNT}"

if [[ -n "${INPUT_FILE}" ]]; then
  echo "    Mode:                PRE-IMPORT (local file)"
  echo "    Input File:          ${INPUT_FILE}"
else
  echo "    Mode:                POST-IMPORT (export from Connect)"
  echo "    Connect Instance ID: ${CONNECT_INSTANCE_ID:-NOT SET}"
  echo "    Flow Name:           ${FLOW_NAME}"
fi
echo ""

###############################################################################
# STEP 1: Discover Real Resource ARNs
###############################################################################
header "STEP 1: Discovering Real Resource ARNs"

# ─── 1a: ParkAndTollBot Lex ARN ────────────────────────────────────────────
info "Looking up Lex bot: ${PARK_BOT_NAME}..."
PARK_BOT_ID=$(aws lexv2-models list-bots \
  --region "${REGION}" \
  --query "botSummaries[?botName=='${PARK_BOT_NAME}'].botId" \
  --output text)

if [[ -z "${PARK_BOT_ID}" || "${PARK_BOT_ID}" == "None" ]]; then
  err "ParkAndTollBot not found!"
  exit 1
fi

PARK_ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "${PARK_BOT_ID}" \
  --region "${REGION}" \
  --query "botAliasSummaries[?botAliasName=='${PARK_BOT_ALIAS_NAME}'].botAliasId" \
  --output text)

if [[ -z "${PARK_ALIAS_ID}" || "${PARK_ALIAS_ID}" == "None" ]]; then
  err "Alias '${PARK_BOT_ALIAS_NAME}' not found for ${PARK_BOT_NAME}!"
  exit 1
fi

PARK_BOT_ARN="arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${PARK_BOT_ID}/${PARK_ALIAS_ID}"
log "ParkAndTollBot ARN: ${PARK_BOT_ARN}"

# ─── 1b: Build Lambda ARN lookup ───────────────────────────────────────────
info "Looking up all Lambda functions in account..."

LAMBDA_CACHE="${WORK_DIR}/lambda-cache.json"
aws lambda list-functions \
  --region "${REGION}" \
  --query "Functions[].{Name:FunctionName, Arn:FunctionArn}" \
  --output json > "${LAMBDA_CACHE}"

LAMBDA_COUNT=$(jq_cmd length "${LAMBDA_CACHE}")
log "Found ${LAMBDA_COUNT} Lambda functions in account"

get_lambda_arn() {
  local func_name="$1"
  if command -v jq &>/dev/null; then
    jq -r --arg name "${func_name}" '.[] | select(.Name == $name) | .Arn' "${LAMBDA_CACHE}"
  else
    "$PY" -c "
import json, sys
data = json.load(open('${LAMBDA_CACHE}'))
print(next((x['Arn'] for x in data if x['Name'] == sys.argv[1]), ''))
" "${func_name}"
  fi
}

###############################################################################
# STEP 2: Load Flow JSON
###############################################################################
header "STEP 2: Loading Flow JSON"

if [[ -n "${INPUT_FILE}" ]]; then
  # ─── Mode 1: Read from local file ──────────────────────────────────────
  if [[ ! -f "${INPUT_FILE}" ]]; then
    err "Input file not found: ${INPUT_FILE}"
    exit 1
  fi

  FLOW_CONTENT=$(cat "${INPUT_FILE}")
  log "Loaded flow from local file: ${INPUT_FILE}"
  SOURCE_DESC="local file"
else
  # ─── Mode 2: Export from Connect ────────────────────────────────────────
  if [[ -z "${CONNECT_INSTANCE_ID:-}" ]]; then
    err "CONNECT_INSTANCE_ID not set in env.sh (required for export mode)"
    exit 1
  fi

  FLOW_ID=$(aws connect list-contact-flows \
    --instance-id "${CONNECT_INSTANCE_ID}" \
    --region "${REGION}" \
    --query "ContactFlowSummaryList[?Name=='${FLOW_NAME}'].Id" \
    --output text)

  if [[ -z "${FLOW_ID}" || "${FLOW_ID}" == "None" ]]; then
    err "Contact flow '${FLOW_NAME}' not found!"
    info "Available flows:"
    aws connect list-contact-flows \
      --instance-id "${CONNECT_INSTANCE_ID}" \
      --region "${REGION}" \
      --query "ContactFlowSummaryList[*].Name" \
      --output table
    exit 1
  fi

  log "Flow ID: ${FLOW_ID}"

  FLOW_CONTENT=$(aws connect describe-contact-flow \
    --instance-id "${CONNECT_INSTANCE_ID}" \
    --contact-flow-id "${FLOW_ID}" \
    --region "${REGION}" \
    --query 'ContactFlow.Content' \
    --output text)

  log "Exported flow from Connect instance"
  SOURCE_DESC="Connect export"
fi

# Save the original
ORIGINAL_FILE="${WORK_DIR}/flow-original-${TIMESTAMP}.json"
echo "${FLOW_CONTENT}" | jq_cmd '.' > "${ORIGINAL_FILE}" 2>/dev/null || echo "${FLOW_CONTENT}" > "${ORIGINAL_FILE}"
log "Original flow saved: ${ORIGINAL_FILE}"

# Count placeholders
PLACEHOLDER_COUNT=$(echo "${FLOW_CONTENT}" | grep -o "${PLACEHOLDER_ACCOUNT}" | wc -l | tr -d ' ' || echo "0")
BOT_PLACEHOLDER_COUNT=$(echo "${FLOW_CONTENT}" | grep -o "PARK_BOT_ID_PLACEHOLDER" | wc -l | tr -d ' ' || echo "0")
info "Found ${PLACEHOLDER_COUNT} placeholder account references"
info "Found ${BOT_PLACEHOLDER_COUNT} bot placeholder references"

if [[ "${PLACEHOLDER_COUNT}" -eq 0 && "${BOT_PLACEHOLDER_COUNT}" -eq 0 ]]; then
  log "No placeholders found — flow already has correct ARNs!"
  info "Verified flow at: ${ORIGINAL_FILE}"
  rm -f "${LAMBDA_CACHE}"
  exit 0
fi

###############################################################################
# STEP 3: Replace All Placeholder ARNs
###############################################################################
header "STEP 3: Replacing Placeholder ARNs"

TEMP_FILE="${WORK_DIR}/flow-temp-${TIMESTAMP}.json"
echo "${FLOW_CONTENT}" > "${TEMP_FILE}"

REPLACEMENTS=0

# ─── 3a: Replace Lex Bot placeholder ───────────────────────────────────────
OLD_BOT_ARN="arn:aws:lex:${REGION}:${PLACEHOLDER_ACCOUNT}:bot-alias/PARK_BOT_ID_PLACEHOLDER/PARK_BOT_ALIAS_PLACEHOLDER"

if grep -q "PARK_BOT_ID_PLACEHOLDER" "${TEMP_FILE}"; then
  sed -i '' "s|${OLD_BOT_ARN}|${PARK_BOT_ARN}|g" "${TEMP_FILE}" 2>/dev/null \
    || sed -i "s|${OLD_BOT_ARN}|${PARK_BOT_ARN}|g" "${TEMP_FILE}"
  BOT_REPLACEMENTS=$(echo "${FLOW_CONTENT}" | grep -o "PARK_BOT_ID_PLACEHOLDER" | wc -l | tr -d ' ')
  REPLACEMENTS=$((REPLACEMENTS + BOT_REPLACEMENTS))
  log "Replaced ${BOT_REPLACEMENTS} Lex bot placeholder(s)"
else
  info "No Lex bot placeholder found (already correct)"
fi

# ─── 3b: Replace Lambda ARN placeholders ───────────────────────────────────
PLACEHOLDER_LAMBDAS=$(grep -o "arn:aws:lambda:${REGION}:${PLACEHOLDER_ACCOUNT}:function:[a-zA-Z0-9_-]*" "${TEMP_FILE}" | sed "s|arn:aws:lambda:${REGION}:${PLACEHOLDER_ACCOUNT}:function:||" | sort -u || true)

if [[ -n "${PLACEHOLDER_LAMBDAS}" ]]; then
  while IFS= read -r FUNC_NAME; do
    [[ -z "${FUNC_NAME}" ]] && continue

    REAL_ARN=$(get_lambda_arn "${FUNC_NAME}")

    if [[ -n "${REAL_ARN}" ]]; then
      OLD_ARN="arn:aws:lambda:${REGION}:${PLACEHOLDER_ACCOUNT}:function:${FUNC_NAME}"
      OCCUR=$(grep -c "${OLD_ARN}" "${TEMP_FILE}" || true)
      sed -i '' "s|${OLD_ARN}|${REAL_ARN}|g" "${TEMP_FILE}" 2>/dev/null \
        || sed -i "s|${OLD_ARN}|${REAL_ARN}|g" "${TEMP_FILE}"
      REPLACEMENTS=$((REPLACEMENTS + OCCUR))
      log "Replaced Lambda (${OCCUR}x): ${FUNC_NAME}"
    else
      warn "Lambda NOT found in account: ${FUNC_NAME}"
    fi
  done <<< "${PLACEHOLDER_LAMBDAS}"
else
  info "No placeholder Lambda ARNs found"
fi

# ─── 3c: Save the updated flow ─────────────────────────────────────────────
UPDATED_FILE="${WORK_DIR}/flow-updated-${TIMESTAMP}.json"
jq_cmd '.' "${TEMP_FILE}" > "${UPDATED_FILE}" 2>/dev/null || cp "${TEMP_FILE}" "${UPDATED_FILE}"

# Verify no placeholders remain
REMAINING_PLACEHOLDERS=$(grep -c "${PLACEHOLDER_ACCOUNT}" "${UPDATED_FILE}" || true)
REMAINING_BOT_PLACEHOLDERS=$(grep -c "PLACEHOLDER" "${UPDATED_FILE}" || true)
REAL_ACCOUNT_REFS=$(grep -c "${ACCOUNT_ID}" "${UPDATED_FILE}" || true)

###############################################################################
# STEP 4: Results
###############################################################################
header "STEP 4: Results"

echo ""
echo "  ┌───────────────────────────────────────────────────────┐"
echo "  │ Replacement Summary                                    │"
echo "  ├───────────────────────────────────────────────────────┤"
printf "  │  Total replacements:        %-4s                      │\n" "${REPLACEMENTS}"
printf "  │  Placeholder account refs:  %-4s (should be 0)       │\n" "${REMAINING_PLACEHOLDERS}"
printf "  │  PLACEHOLDER strings:       %-4s (should be 0)       │\n" "${REMAINING_BOT_PLACEHOLDERS}"
printf "  │  Real account refs:         %-4s (should be > 0)     │\n" "${REAL_ACCOUNT_REFS}"
echo "  ├───────────────────────────────────────────────────────┤"
echo "  │ Files                                                  │"
echo "  │  Original: ${ORIGINAL_FILE}"
echo "  │  Updated:  ${UPDATED_FILE}"
echo "  └───────────────────────────────────────────────────────┘"

# Cleanup temp files
rm -f "${TEMP_FILE}" "${LAMBDA_CACHE}"

if [[ "${REMAINING_PLACEHOLDERS}" -gt 0 || "${REMAINING_BOT_PLACEHOLDERS}" -gt 0 ]]; then
  echo ""
  warn "Some placeholders remain — review the updated file before importing."
  echo ""
  info "Remaining placeholder lines:"
  grep -n "${PLACEHOLDER_ACCOUNT}\|PLACEHOLDER" "${UPDATED_FILE}" | head -20 || true
fi

###############################################################################
# STEP 5: Next Steps
###############################################################################
header "STEP 5: Next Steps"

echo ""
echo -e "${BOLD}  The updated flow has been saved to:${NC}"
echo "    ${UPDATED_FILE}"
echo ""
echo -e "${BOLD}  To import into Amazon Connect:${NC}"
echo ""
echo "  Option A — Import via Console (new flow):"
echo "    1. Open Amazon Connect console → Contact flows"
echo "    2. Click 'Create contact flow' (or open existing flow)"
echo "    3. Click the dropdown arrow next to 'Save' → 'Import (JSON)'"
echo "    4. Select: ${UPDATED_FILE}"
echo "    5. Click 'Save' then 'Publish'"
echo ""

if [[ -z "${INPUT_FILE}" && -n "${FLOW_ID:-}" ]]; then
  echo "  Option B — Update existing flow via CLI:"
  echo "    aws connect update-contact-flow-content \\"
  echo "      --instance-id ${CONNECT_INSTANCE_ID} \\"
  echo "      --contact-flow-id ${FLOW_ID} \\"
  echo "      --content 'file://${UPDATED_FILE}' \\"
  echo "      --region ${REGION}"
  echo ""
  echo "    Then activate it:"
  echo "    aws connect update-contact-flow-metadata \\"
  echo "      --instance-id ${CONNECT_INSTANCE_ID} \\"
  echo "      --contact-flow-id ${FLOW_ID} \\"
  echo "      --contact-flow-state ACTIVE \\"
  echo "      --region ${REGION}"
  echo ""
fi

echo -e "${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  ✅ Flow JSON updated successfully!                 ║"
echo "  ║  Import it using the steps above.                   ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
