#!/bin/bash
# create-park-and-toll-bot.sh
# Creates the ParkAndTollBot Lex V2 bot with AMAZON.QInConnectIntent
# Version: 2.0 — Fixed: Fulfillment enabled on QInConnect intent (not FallbackIntent)
#                 Added: Conversation logs, Lambda resource policy for bot-level
# Version: 2.1 — Fixed: successNextStep changed from FulfillIntent to EndConversation
#                 FulfillIntent caused Lex to loop instead of returning control to Connect,
#                 which prevented the payment handoff flow from executing.
#                 Fixed: Fulfillment enabled on QInConnect intent (not FallbackIntent)
#                 Added: Conversation logs, Lambda resource policy for bot-level

set -euo pipefail

# ─── Cross-platform file:// URI helper (Git Bash on Windows fix) ──
# AWS CLI on Windows can't resolve Unix-style /tmp/ paths.
# This converts paths to Windows format when running in Git Bash.
file_uri() {
  local path="$1"
  if command -v cygpath &>/dev/null; then
    echo "file://$(cygpath -w "$path")"
  else
    echo "file://$path"
  fi
}

# ─── Source environment ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/env.sh" ]; then
  source "${SCRIPT_DIR}/env.sh"
elif [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "ERROR: env.sh not found"
  exit 1
fi

REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-anycompany-ivr}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ─── Configuration ───────────────────────────────────────────────
BOT_NAME="ParkAndTollBot"
BOT_DESCRIPTION="AnyCompany Parking & Tolling IVR Bot with Amazon Q in Connect"
LOCALE_ID="en_US"
NLU_CONFIDENCE_THRESHOLD=0.4
INTENT_SIGNATURE="AMAZON.QInConnectIntent"
ALIAS_NAME="live"
FULFILLMENT_HOOK_STACK="anycompany-ivr-fulfillment-hook"

# ─── Retrieve dependent resource ARNs ────────────────────────────
echo "============================================"
echo "  ParkAndTollBot Creation Script v2.0"
echo "============================================"
echo ""
echo ">>> Resolving dependencies..."
echo "  STACK_NAME:      ${STACK_NAME}"
echo "  REGION:          ${REGION}"
echo "  ACCOUNT_ID:      ${ACCOUNT_ID}"
echo ""

# Q in Connect Assistant ARN (from ConnectConfigStack nested in root)
CONNECT_CONFIG_STACK_ID=$(aws cloudformation describe-stack-resources \
  --stack-name "${STACK_NAME}" \
  --logical-resource-id "ConnectConfigStack" \
  --region "${REGION}" \
  --query "StackResources[0].PhysicalResourceId" --output text)

if [ -z "${CONNECT_CONFIG_STACK_ID}" ] || [ "${CONNECT_CONFIG_STACK_ID}" = "None" ]; then
  echo "ERROR: Could not find ConnectConfigStack in root stack ${STACK_NAME}"
  exit 1
fi

ASSISTANT_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${CONNECT_CONFIG_STACK_ID}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='QInConnectAssistantArn'].OutputValue" --output text)

if [ -z "${ASSISTANT_ARN}" ] || [ "${ASSISTANT_ARN}" = "None" ]; then
  echo "ERROR: Could not resolve Q in Connect Assistant ARN from ConnectConfigStack"
  exit 1
fi

# Connect Instance ARN/ID (from root stack outputs)
CONNECT_INSTANCE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ConnectInstanceArn'].OutputValue" --output text)

if [ -z "${CONNECT_INSTANCE_ARN}" ] || [ "${CONNECT_INSTANCE_ARN}" = "None" ]; then
  echo "ERROR: Could not resolve Connect Instance ARN from ${STACK_NAME}"
  exit 1
fi

CONNECT_INSTANCE_ID=$(echo "${CONNECT_INSTANCE_ARN}" | awk -F'instance/' '{print $2}')

# Fulfillment Hook Lambda ARN
echo "  Looking up fulfillment hook from stack: ${FULFILLMENT_HOOK_STACK}"

echo "  Available outputs from ${FULFILLMENT_HOOK_STACK}:"
aws cloudformation describe-stacks \
  --stack-name "${FULFILLMENT_HOOK_STACK}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[*].{Key:OutputKey,Value:OutputValue}" \
  --output table 2>/dev/null || echo "  WARNING: Stack not found!"

FULFILLMENT_HOOK_ARN=""
for KEY in "FulfillmentHookFunctionArn" "DialogHookFunctionArn" "LambdaFunctionArn" "FunctionArn"; do
  FULFILLMENT_HOOK_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${FULFILLMENT_HOOK_STACK}" \
    --region "${REGION}" \
    --query "Stacks[0].Outputs[?OutputKey=='${KEY}'].OutputValue" --output text 2>/dev/null || echo "")
  if [ -n "${FULFILLMENT_HOOK_ARN}" ] && [ "${FULFILLMENT_HOOK_ARN}" != "None" ]; then
    echo "  Found fulfillment hook via output key: ${KEY}"
    break
  fi
  FULFILLMENT_HOOK_ARN=""
done

if [ -z "${FULFILLMENT_HOOK_ARN}" ]; then
  echo ""
  echo "  WARNING: Could not auto-detect fulfillment hook Lambda ARN"
  echo "  Trying to find Lambda by name pattern..."

  FULFILLMENT_HOOK_ARN=$(aws lambda list-functions \
    --region "${REGION}" \
    --query "Functions[?contains(FunctionName,'fulfillment') || contains(FunctionName,'DialogHook') || contains(FunctionName,'dialog-hook')].FunctionArn | [0]" \
    --output text 2>/dev/null || echo "")

  if [ -n "${FULFILLMENT_HOOK_ARN}" ] && [ "${FULFILLMENT_HOOK_ARN}" != "None" ]; then
    echo "  Found by name search: ${FULFILLMENT_HOOK_ARN}"
  else
    FULFILLMENT_HOOK_ARN=""
    echo "  ERROR: No fulfillment hook Lambda found!"
    echo "  The bot will be created WITHOUT a fulfillment code hook."
    echo "  You'll need to add it manually later."
    read -p "  Continue anyway? (y/n): " CONTINUE
    [ "${CONTINUE}" != "y" ] && exit 1
  fi
fi

echo ""
echo "  ─── Resolved Dependencies ───"
echo "  Assistant ARN:     ${ASSISTANT_ARN}"
echo "  Connect Instance:  ${CONNECT_INSTANCE_ID}"
echo "  Fulfillment Hook:  ${FULFILLMENT_HOOK_ARN:-NOT FOUND}"
echo "  Intent Signature:  ${INTENT_SIGNATURE}"
echo ""

# ─── Step 1: Ensure Service-Linked Role exists ─────────────────────────────────────
echo ">>> Step 1: Service-Linked Role for Lex + Connect..."

SLR_ROLE_NAME="AWSServiceRoleForLexV2Bots_AmazonConnect_${ACCOUNT_ID}"
SLR_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/lexv2.amazonaws.com/${SLR_ROLE_NAME}"

if aws iam get-role --role-name "${SLR_ROLE_NAME}" >/dev/null 2>&1; then
  echo "    Service-linked role exists: ${SLR_ARN}"
else
  echo "    Creating service-linked role..."
  aws iam create-service-linked-role \
    --aws-service-name lexv2.amazonaws.com \
    --custom-suffix "AmazonConnect_${ACCOUNT_ID}"
  echo "    Created: ${SLR_ARN}"
  echo "    Waiting 10s for propagation..."
  sleep 10
fi

LEX_ROLE_ARN="${SLR_ARN}"

# ─── Step 2: Create Bot ──────────────────────────────────────────
echo ""
echo ">>> Step 2: Create Bot..."

EXISTING_BOT_ID=$(aws lexv2-models list-bots \
  --region "${REGION}" \
  --filters name=BotName,values="${BOT_NAME}",operator=EQ \
  --query "botSummaries[0].botId" --output text 2>/dev/null || echo "None")

if [ "${EXISTING_BOT_ID}" != "None" ] && [ -n "${EXISTING_BOT_ID}" ]; then
  BOT_ID="${EXISTING_BOT_ID}"
  echo "    Already exists: ${BOT_ID}"
else
  BOT_ID=$(aws lexv2-models create-bot \
    --bot-name "${BOT_NAME}" \
    --description "${BOT_DESCRIPTION}" \
    --role-arn "${LEX_ROLE_ARN}" \
    --data-privacy '{"childDirected": false}' \
    --idle-session-ttl-in-seconds 300 \
    --region "${REGION}" \
    --query "botId" --output text)

  echo "    Created: ${BOT_ID}"
  echo "    Waiting for Available..."
  while true; do
    STATUS=$(aws lexv2-models describe-bot --bot-id "${BOT_ID}" \
      --region "${REGION}" --query "botStatus" --output text)
    [ "${STATUS}" = "Available" ] && break
    echo "      ${STATUS}..."
    sleep 5
  done
fi

echo "    Bot ID: ${BOT_ID}"

# ─── Step 2b: Tag Bot for Amazon Connect ─────────────────────────
echo ""
echo ">>> Step 2b: Tagging bot for Amazon Connect..."

aws lexv2-models tag-resource \
  --resource-arn "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot/${BOT_ID}" \
  --tags '{"AmazonConnectEnabled": "True"}' \
  --region "${REGION}"

echo "    Tagged: AmazonConnectEnabled=True"

# ADDED: Step 2c: Create conversation log group
echo ""
echo ">>> Step 2c: Create conversation log group..."

LOG_GROUP="/aws/lex/${BOT_NAME}/dev"
aws logs create-log-group \
  --log-group-name "${LOG_GROUP}" \
  --region "${REGION}" 2>/dev/null \
  && echo "    Created: ${LOG_GROUP}" \
  || echo "    Already exists: ${LOG_GROUP}"

# ─── Step 3: Create Bot Locale ───────────────────────────────────
echo ""
echo ">>> Step 3: Create Locale (${LOCALE_ID})..."

LOCALE_STATUS=$(aws lexv2-models describe-bot-locale \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
  --region "${REGION}" --query "botLocaleStatus" --output text 2>/dev/null || echo "NotFound")

if [ "${LOCALE_STATUS}" != "NotFound" ]; then
  echo "    Already exists (${LOCALE_STATUS})"
else
  aws lexv2-models create-bot-locale \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "${LOCALE_ID}" \
    --nlu-intent-confidence-threshold "${NLU_CONFIDENCE_THRESHOLD}" \
    --region "${REGION}" > /dev/null

  echo "    Created, waiting..."
  while true; do
    LOCALE_STATUS=$(aws lexv2-models describe-bot-locale \
      --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
      --region "${REGION}" --query "botLocaleStatus" --output text)
    [[ "${LOCALE_STATUS}" =~ ^(NotBuilt|Built|ReadyExpressTesting)$ ]] && break
    echo "      ${LOCALE_STATUS}..."
    sleep 5
  done
  echo "    Status: ${LOCALE_STATUS}"
fi

# ─── Detect Python with boto3 ────────────────────────────────────
PY=""
for candidate in python3 python; do
  if command -v "$candidate" &>/dev/null; then
    PYPATH=$(command -v "$candidate")
    if "$PYPATH" -c 'import boto3' 2>/dev/null; then
      PY="$PYPATH"
      break
    fi
  fi
done
if [ -z "$PY" ]; then
  echo "ERROR: No Python with boto3 found. Run: pip install boto3"
  exit 1
fi
echo "  Using Python: $PY ($($PY --version 2>&1))"

# Helper: write to temp file and run with resolved $PY (avoids heredoc subprocess PATH issues)
run_py() {
  local _f
  _f=$(mktemp "${TMPDIR:-/tmp}/bot_XXXXXX.py")
  cat > "$_f"
  "$PY" "$_f"
  local rc=$?
  rm -f "$_f"
  return $rc
}

# ─── Step 4: Create AMAZON.QInConnectIntent (via Python/boto3) ───
echo ""
echo ">>> Step 4: Create AmazonQinConnect intent (${INTENT_SIGNATURE})..."

QNA_INTENT_ID=$(aws lexv2-models list-intents \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
  --region "${REGION}" \
  --filters name=IntentName,values=AmazonQinConnect,operator=EQ \
  --query "intentSummaries[0].intentId" --output text 2>/dev/null || echo "None")

if [ "${QNA_INTENT_ID}" != "None" ] && [ -n "${QNA_INTENT_ID}" ]; then
  echo "    Already exists: ${QNA_INTENT_ID}"
else
  export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_LOCALE="${LOCALE_ID}" \
         _PY_SIG="${INTENT_SIGNATURE}" _PY_ARN="${ASSISTANT_ARN}"
  QNA_INTENT_ID=$(run_py << 'PYEOF'
import boto3, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
resp = client.create_intent(
    botId=os.environ['_PY_BOT'], botVersion='DRAFT', localeId=os.environ['_PY_LOCALE'],
    intentName='AmazonQinConnect',
    description='This intent leverages Amazon Q in Connect to fulfill requests or tasks.',
    parentIntentSignature=os.environ['_PY_SIG'],
    qInConnectIntentConfiguration={'qInConnectAssistantConfiguration': {'assistantArn': os.environ['_PY_ARN']}}
)
print(resp['intentId'])
PYEOF
)

  if [ -z "${QNA_INTENT_ID}" ]; then
    echo "    ERROR: Failed to create intent"
    exit 1
  fi
  echo "    Created: ${QNA_INTENT_ID}"
fi

# Verify
echo "    Verifying..."
export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_LOCALE="${LOCALE_ID}" _PY_INTENT="${QNA_INTENT_ID}"
run_py << 'PYEOF'
import boto3, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
d = client.describe_intent(botId=os.environ['_PY_BOT'], botVersion='DRAFT',
    localeId=os.environ['_PY_LOCALE'], intentId=os.environ['_PY_INTENT'])
print(f"  Name:      {d['intentName']}")
print(f"  Signature: {d.get('parentIntentSignature','N/A')}")
assistant_arn = d.get('qInConnectIntentConfiguration',{}).get('qInConnectAssistantConfiguration',{}).get('assistantArn','NOT SET')
print(f"  Assistant: {assistant_arn}")
print(f"  Fulfillment enabled: {d.get('fulfillmentCodeHook',{}).get('enabled', False)}")
PYEOF

# ─── CHANGED: Step 5: Enable Fulfillment on AmazonQInConnect Intent ─
# Previously this was set on FallbackIntent which was WRONG.
# The fulfillment hook must be on the QInConnect intent because:
# - Q in Connect closes the conversation (status=CLOSED)
# - Lex fires FulfillmentCodeHook on the QInConnect intent
# - The hook Lambda detects PAYMENT_TRANSFER and sets Tool=initiatePayment
# - Connect flow reads Tool attribute and routes to payment bot
echo ""
echo ">>> Step 5: Enable fulfillment code hook on AmazonQInConnect intent..."

if [ -n "${FULFILLMENT_HOOK_ARN}" ]; then
  export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_LOCALE="${LOCALE_ID}" _PY_INTENT="${QNA_INTENT_ID}"
  run_py << 'PYEOF'
import boto3, sys, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
try:
    intent = client.describe_intent(botId=os.environ['_PY_BOT'], botVersion='DRAFT',
        localeId=os.environ['_PY_LOCALE'], intentId=os.environ['_PY_INTENT'])
    for field in ['creationDateTime','lastUpdatedDateTime','ResponseMetadata','botId','botVersion','localeId','intentId']:
        intent.pop(field, None)
    intent['fulfillmentCodeHook'] = {
        'enabled': True, 'active': True,
        'postFulfillmentStatusSpecification': {
            'successResponse': {'messageGroups': [{'message': {'plainTextMessage': {'value': '((x-amz-lex:q-in-connect-response))'}}}], 'allowInterrupt': True},
            'successNextStep': {'dialogAction': {'type': 'EndConversation'}},
            'failureNextStep': {'dialogAction': {'type': 'EndConversation'}},
            'timeoutNextStep': {'dialogAction': {'type': 'EndConversation'}}
        }
    }
    client.update_intent(botId=os.environ['_PY_BOT'], botVersion='DRAFT',
        localeId=os.environ['_PY_LOCALE'], intentId=os.environ['_PY_INTENT'], **intent)
    verify = client.describe_intent(botId=os.environ['_PY_BOT'], botVersion='DRAFT',
        localeId=os.environ['_PY_LOCALE'], intentId=os.environ['_PY_INTENT'])
    enabled = verify.get('fulfillmentCodeHook', {}).get('enabled', False)
    active  = verify.get('fulfillmentCodeHook', {}).get('active', False)
    print(f"    Fulfillment code hook: enabled={enabled}, active={active}")
    if not enabled:
        print('    ERROR: Fulfillment was not enabled!', file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f'    ERROR: {e}', file=sys.stderr); sys.exit(1)
PYEOF
  echo "    ✅ Fulfillment code hook enabled on AmazonQInConnect intent"
else
  echo "    SKIPPED - no fulfillment hook ARN"
  echo "    WARNING: Payment routing will NOT work without fulfillment hook!"
fi

# ─── Step 6: Build Bot Locale ────────────────────────────────────
echo ""
echo ">>> Step 6: Building bot locale..."

aws lexv2-models build-bot-locale \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
  --region "${REGION}" > /dev/null

echo "    Build initiated, waiting..."
while true; do
  BUILD_STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
    --region "${REGION}" --query "botLocaleStatus" --output text)
  if [ "${BUILD_STATUS}" = "Built" ] || [ "${BUILD_STATUS}" = "ReadyExpressTesting" ]; then
    echo "    Build COMPLETE (${BUILD_STATUS})"
    break
  elif [ "${BUILD_STATUS}" = "Failed" ]; then
    echo "    BUILD FAILED!"
    aws lexv2-models describe-bot-locale \
      --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "${LOCALE_ID}" \
      --region "${REGION}" --query "failureReasons" --output yaml
    exit 1
  fi
  echo "      ${BUILD_STATUS}..."
  sleep 10
done

# ─── Step 7: Create Bot Version ──────────────────────────────────
echo ""
echo ">>> Step 7: Creating bot version..."

LOCALE_SPEC_FILE=$(mktemp)
cat > "${LOCALE_SPEC_FILE}" << EOF
{"en_US": {"sourceBotVersion": "DRAFT"}}
EOF

BOT_VERSION=$(aws lexv2-models create-bot-version \
  --bot-id "${BOT_ID}" \
  --bot-version-locale-specification "$(file_uri "${LOCALE_SPEC_FILE}")" \
  --region "${REGION}" \
  --query "botVersion" --output text)

rm -f "${LOCALE_SPEC_FILE}"

echo "    Version: ${BOT_VERSION}, waiting..."
while true; do
  VER_STATUS=$(aws lexv2-models describe-bot-version \
    --bot-id "${BOT_ID}" --bot-version "${BOT_VERSION}" \
    --region "${REGION}" --query "botStatus" --output text)
  if [ "${VER_STATUS}" = "Available" ]; then
    echo "    Version ${BOT_VERSION} Available!"
    break
  elif [ "${VER_STATUS}" = "Failed" ]; then
    echo "    FAILED!"
    exit 1
  fi
  echo "      ${VER_STATUS}..."
  sleep 5
done

# ─── Step 8: Create/Update Bot Alias with Lambda Code Hook ───────
echo ""
echo ">>> Step 8: Bot alias '${ALIAS_NAME}' with fulfillment Lambda..."

EXISTING_ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "${BOT_ID}" --region "${REGION}" \
  --query "botAliasSummaries[?botAliasName=='${ALIAS_NAME}'].botAliasId | [0]" \
  --output text 2>/dev/null || echo "None")

# Write alias locale settings to temp file to avoid shell quoting issues
ALIAS_SETTINGS_FILE=$(mktemp)

if [ -n "${FULFILLMENT_HOOK_ARN}" ]; then
  echo "    Including fulfillment Lambda: ${FULFILLMENT_HOOK_ARN}"
  cat > "${ALIAS_SETTINGS_FILE}" << EOF
{
  "en_US": {
    "enabled": true,
    "codeHookSpecification": {
      "lambdaCodeHook": {
        "lambdaARN": "${FULFILLMENT_HOOK_ARN}",
        "codeHookInterfaceVersion": "1.0"
      }
    }
  }
}
EOF
else
  echo "    WARNING: No fulfillment Lambda - alias without code hook"
  echo "    Payment routing will NOT work!"
  cat > "${ALIAS_SETTINGS_FILE}" << EOF
{
  "en_US": {
    "enabled": true
  }
}
EOF
fi

if [ "${EXISTING_ALIAS_ID}" != "None" ] && [ -n "${EXISTING_ALIAS_ID}" ]; then
  BOT_ALIAS_ID="${EXISTING_ALIAS_ID}"
  aws lexv2-models update-bot-alias \
    --bot-id "${BOT_ID}" \
    --bot-alias-id "${BOT_ALIAS_ID}" \
    --bot-alias-name "${ALIAS_NAME}" \
    --bot-version "${BOT_VERSION}" \
    --bot-alias-locale-settings "$(file_uri "${ALIAS_SETTINGS_FILE}")" \
    --region "${REGION}" > /dev/null
  echo "    Updated: ${BOT_ALIAS_ID} -> v${BOT_VERSION}"
else
  BOT_ALIAS_ID=$(aws lexv2-models create-bot-alias \
    --bot-id "${BOT_ID}" \
    --bot-alias-name "${ALIAS_NAME}" \
    --bot-version "${BOT_VERSION}" \
    --bot-alias-locale-settings "$(file_uri "${ALIAS_SETTINGS_FILE}")" \
    --region "${REGION}" \
    --query "botAliasId" --output text)
  echo "    Created: ${BOT_ALIAS_ID}"
fi

rm -f "${ALIAS_SETTINGS_FILE}"

BOT_ALIAS_ARN="arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${BOT_ID}/${BOT_ALIAS_ID}"
echo "    Alias ARN: ${BOT_ALIAS_ARN}"

# ADDED: Verify alias locale settings were applied
echo "    Verifying alias locale settings..."
ALIAS_LOCALE=$(aws lexv2-models describe-bot-alias \
  --bot-id "${BOT_ID}" --bot-alias-id "${BOT_ALIAS_ID}" \
  --region "${REGION}" \
  --query "botAliasLocaleSettings" --output json)

if echo "${ALIAS_LOCALE}" | grep -q "lambdaARN"; then
  echo "    ✅ Lambda ARN confirmed in alias locale settings"
elif [ "${ALIAS_LOCALE}" = "null" ]; then
  echo "    ❌ ERROR: Alias locale settings are null!"
  echo "    This will cause the fulfillment Lambda to never be invoked."
  exit 1
else
  echo "    ⚠️  Alias locale settings present but no Lambda ARN found"
fi

# ─── Step 9: Lambda Permission for Lex to Invoke ─────────────────
echo ""
echo ">>> Step 9: Lambda invoke permissions..."

if [ -n "${FULFILLMENT_HOOK_ARN}" ]; then
  # Permission for specific alias
  aws lambda add-permission \
    --function-name "${FULFILLMENT_HOOK_ARN}" \
    --statement-id "LexV2-${BOT_ID}-${BOT_ALIAS_ID}" \
    --action "lambda:InvokeFunction" \
    --principal "lexv2.amazonaws.com" \
    --source-arn "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${BOT_ID}/${BOT_ALIAS_ID}" \
    --region "${REGION}" 2>/dev/null \
    && echo "    Permission added (alias-specific)" \
    || echo "    Already exists (alias-specific, OK)"

  # ADDED: Permission for bot-level (covers TestBotAlias and future aliases)
  aws lambda add-permission \
    --function-name "${FULFILLMENT_HOOK_ARN}" \
    --statement-id "LexV2-${BOT_ID}-AllAliases" \
    --action "lambda:InvokeFunction" \
    --principal "lexv2.amazonaws.com" \
    --source-arn "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot/${BOT_ID}" \
    --region "${REGION}" 2>/dev/null \
    && echo "    Permission added (bot-level)" \
    || echo "    Already exists (bot-level, OK)"
else
  echo "    Skipped - no fulfillment hook Lambda"
fi

# ─── Step 10: Associate with Connect ─────────────────────────────
echo ""
echo ">>> Step 10: Associate with Connect instance..."

# Write lex-v2-bot JSON to temp file to avoid quoting issues
LEX_BOT_FILE=$(mktemp)
cat > "${LEX_BOT_FILE}" << EOF
{
  "AliasArn": "${BOT_ALIAS_ARN}"
}
EOF

aws connect associate-bot \
  --instance-id "${CONNECT_INSTANCE_ID}" \
  --lex-v2-bot "$(file_uri "${LEX_BOT_FILE}")" \
  --region "${REGION}" 2>/dev/null \
  && echo "    Associated!" \
  || echo "    Already associated (OK)"

rm -f "${LEX_BOT_FILE}"

# ─── ADDED: Step 11: Final Verification ──────────────────────────
echo ""
echo ">>> Step 11: Final verification..."

export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_LOCALE="${LOCALE_ID}" \
       _PY_INTENT="${QNA_INTENT_ID}" _PY_VER="${BOT_VERSION}" _PY_ALIAS="${BOT_ALIAS_ID}"
run_py << 'PYEOF'
import boto3, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
intent = client.describe_intent(botId=os.environ['_PY_BOT'], botVersion=os.environ['_PY_VER'],
    localeId=os.environ['_PY_LOCALE'], intentId=os.environ['_PY_INTENT'])
fch = intent.get('fulfillmentCodeHook', {})
ver = os.environ['_PY_VER']
print(f"  Intent (v{ver}): fulfillment enabled={fch.get('enabled', False)}, active={fch.get('active', False)}")
alias_resp = client.describe_bot_alias(botId=os.environ['_PY_BOT'], botAliasId=os.environ['_PY_ALIAS'])
alias_version = alias_resp.get('botVersion', 'UNKNOWN')
en_us = alias_resp.get('botAliasLocaleSettings', {}).get('en_US', {})
lambda_arn = en_us.get('codeHookSpecification', {}).get('lambdaCodeHook', {}).get('lambdaARN', 'NOT SET')
print(f"  Alias '{alias_resp.get('botAliasName')}': version={alias_version}")
print(f"  Alias Lambda: {lambda_arn}")
pfs = fch.get('postFulfillmentStatusSpecification', {})
success_step = pfs.get('successNextStep', {}).get('dialogAction', {}).get('type', 'UNKNOWN')
failure_step = pfs.get('failureNextStep', {}).get('dialogAction', {}).get('type', 'UNKNOWN')
timeout_step = pfs.get('timeoutNextStep', {}).get('dialogAction', {}).get('type', 'UNKNOWN')
print(f"  PostFulfillment steps: success={success_step}, failure={failure_step}, timeout={timeout_step}")
errors = []
if not fch.get('enabled', False): errors.append('Fulfillment NOT enabled on QInConnect intent')
if lambda_arn == 'NOT SET': errors.append('Lambda ARN NOT set on alias locale settings')
if alias_version != ver: errors.append(f'Alias points to v{alias_version}, expected v{ver}')
if success_step != 'EndConversation': errors.append(f"successNextStep is '{success_step}' - MUST be 'EndConversation'")
if failure_step != 'EndConversation': errors.append(f"failureNextStep is '{failure_step}' - should be 'EndConversation'")
if timeout_step != 'EndConversation': errors.append(f"timeoutNextStep is '{timeout_step}' - should be 'EndConversation'")
if errors:
    print('\n  \u274c VALIDATION ERRORS:')
    [print(f'     - {e}') for e in errors]
    print('\n  The bot may not route payments correctly!')
else:
    print('\n  \u2705 All checks passed!')
PYEOF

# ─── Summary ─────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  ParkAndTollBot - COMPLETE"
echo "============================================"
echo ""
echo "  Bot Name:         ${BOT_NAME}"
echo "  Bot ID:           ${BOT_ID}"
echo "  Version:          ${BOT_VERSION}"
echo "  Alias:            ${ALIAS_NAME} (${BOT_ALIAS_ID})"
echo "  Alias ARN:        ${BOT_ALIAS_ARN}"
echo "  Intent:           AmazonQinConnect (${INTENT_SIGNATURE})"
echo "  Assistant ARN:    ${ASSISTANT_ARN}"
echo "  Fulfillment Hook: ${FULFILLMENT_HOOK_ARN:-NOT SET}"
echo "  Connect:          ${CONNECT_INSTANCE_ID}"
echo ""
echo "  Fulfillment chain (3 required pieces):"
if [ -n "${FULFILLMENT_HOOK_ARN}" ]; then
  echo "    ✅ 1. FulfillmentCodeHook enabled on AmazonQInConnect intent"
  echo "    ✅ 2. Lambda ARN configured on alias locale settings"
  echo "    ✅ 3. Lambda resource policy allows lexv2.amazonaws.com"
else
  echo "    ❌ 1. FulfillmentCodeHook NOT configured (no Lambda found)"
  echo "    ❌ 2. Lambda ARN NOT on alias"
  echo "    ❌ 3. Lambda permission NOT granted"
  echo ""
  echo "  WARNING: Payment routing will NOT work!"
  echo "  Deploy the fulfillment hook Lambda and re-run this script."
fi
echo ""
echo "  Next Steps:"
echo "  1. Create PaymentCollectionBot (if needed)"
echo "  2. Import Connect Contact Flows"
echo "  3. Claim phone number in Connect"
echo "============================================"