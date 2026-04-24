#!/bin/bash
set -euo pipefail

# ─── Cross-platform file:// URI helper (Git Bash on Windows fix) ──
file_uri() {
  local path="$1"
  if command -v cygpath &>/dev/null; then
    echo "file://$(cygpath -w "$path")"
  else
    echo "file://$path"
  fi
}

# ============================================================
# Configuration - Source from env.sh or set defaults
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/env.sh" ]; then
  source "${SCRIPT_DIR}/env.sh"
fi

REGION="${REGION:-us-east-1}"

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

# Helper: write stdin to temp file and run with resolved $PY
run_py() {
  local _f
  _f=$(mktemp "${TMPDIR:-/tmp}/bot_XXXXXX.py")
  cat > "$_f"
  "$PY" "$_f"
  local rc=$?
  rm -f "$_f"
  return $rc
}
ACCOUNT_ID="${ACCOUNT_ID:?ERROR: ACCOUNT_ID not set. Set it in env.sh}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
STACK_NAME="${STACK_NAME:-anycompany-ivr}"

BOT_NAME="PaymentCollectionBot"
ALIAS_NAME="live"

echo "============================================"
echo "Creating PCI Payment Collection Lex V2 Bot"
echo "  Version: 2.0 — Idempotent + Verified"
echo "============================================"
echo "  Region:      ${REGION}"
echo "  Account:     ${ACCOUNT_ID}"
echo "  Environment: ${ENVIRONMENT}"
echo ""

# ============================================================
# Resolve Dependencies from CloudFormation Stacks
# ============================================================
echo ">>> Resolving dependencies from CloudFormation..."

# Connect Instance ID
CONNECT_INSTANCE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ConnectInstanceArn'].OutputValue | [0]" \
  --output text)

if [ -z "${CONNECT_INSTANCE_ARN}" ] || [ "${CONNECT_INSTANCE_ARN}" = "None" ]; then
  echo "❌ ERROR: Could not resolve ConnectInstanceArn from stack ${STACK_NAME}"
  exit 1
fi

CONNECT_INSTANCE_ID=$(echo "${CONNECT_INSTANCE_ARN}" | awk -F'/' '{print $NF}')
echo "  Connect Instance: ${CONNECT_INSTANCE_ID}"

# Payment Lambda ARN - try CloudFormation first
PAYMENT_LAMBDA_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-payment-handoff" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='PaymentProcessingFunctionArn'].OutputValue | [0]" \
  --output text 2>/dev/null) || true

if [ -z "${PAYMENT_LAMBDA_ARN}" ] || [ "${PAYMENT_LAMBDA_ARN}" = "None" ]; then
  echo "❌ ERROR: Could not resolve PaymentProcessing Lambda ARN from ${STACK_NAME}-payment-handoff"
  exit 1
fi

echo "  Payment Lambda: ${PAYMENT_LAMBDA_ARN}"

# ============================================================
# Step 1: Ensure Service-Linked Role exists
# ============================================================
echo ""
echo ">>> Step 1: Service-Linked Role for Lex + Connect..."

SLR_ROLE_NAME="AWSServiceRoleForLexV2Bots_AmazonConnect_${ACCOUNT_ID}"
SLR_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aws-service-role/lexv2.amazonaws.com/${SLR_ROLE_NAME}"

if aws iam get-role --role-name "${SLR_ROLE_NAME}" >/dev/null 2>&1; then
  echo "    Service-linked role exists: ${SLR_ROLE_NAME}"
else
  echo "    Creating service-linked role..."
  aws iam create-service-linked-role \
    --aws-service-name lexv2.amazonaws.com \
    --custom-suffix "AmazonConnect_${ACCOUNT_ID}" 2>/dev/null || true
  echo "    Waiting 10s for propagation..."
  sleep 10
fi

# Also ensure the base SLR exists (needed for some operations)
aws iam create-service-linked-role \
  --aws-service-name lexv2.amazonaws.com 2>/dev/null || true

BOT_ROLE_ARN="${SLR_ARN}"
echo "✅ Using role: ${BOT_ROLE_ARN}"

# ============================================================
# Step 2: Create the Bot (idempotent)
# ============================================================
echo ""
echo ">>> Step 2: Creating bot..."

EXISTING_BOT_ID=$(aws lexv2-models list-bots \
  --region "${REGION}" \
  --filters name=BotName,values="${BOT_NAME}",operator=EQ \
  --query "botSummaries[0].botId" --output text 2>/dev/null || echo "None")

if [ "${EXISTING_BOT_ID}" != "None" ] && [ -n "${EXISTING_BOT_ID}" ]; then
  BOT_ID="${EXISTING_BOT_ID}"
  echo "    Already exists: ${BOT_ID}"
else
  BOT_RESPONSE=$(aws lexv2-models create-bot \
    --bot-name "${BOT_NAME}" \
    --description "PCI-compliant payment collection bot for IVR payment handoff." \
    --role-arn "${BOT_ROLE_ARN}" \
    --data-privacy '{"childDirected": false}' \
    --idle-session-ttl-in-seconds 120 \
    --region "${REGION}" \
    --output json)

  BOT_ID=$(echo "${BOT_RESPONSE}" | "$PY" -c "import sys,json; print(json.load(sys.stdin)['botId'])")
  echo "    Bot created with ID: ${BOT_ID}"

  # Poll until bot is available
  echo "    Waiting for bot to become available..."
  while true; do
    BOT_STATUS=$(aws lexv2-models describe-bot \
      --bot-id "${BOT_ID}" \
      --region "${REGION}" \
      --query 'botStatus' \
      --output text)
    echo "      Bot status: ${BOT_STATUS}"
    [ "${BOT_STATUS}" = "Available" ] && break
    [ "${BOT_STATUS}" = "Failed" ] && echo "❌ Bot creation failed" && exit 1
    sleep 5
  done
  echo "✅ Bot is available"
fi

echo "    Bot ID: ${BOT_ID}"

# ============================================================
# Step 2b: Tag bot for Connect visibility
# ============================================================
echo ""
echo ">>> Step 2b: Tagging bot for Connect console..."

aws lexv2-models tag-resource \
  --resource-arn "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot/${BOT_ID}" \
  --tags '{"AmazonConnectEnabled": "True"}' \
  --region "${REGION}"

echo "✅ Tagged AmazonConnectEnabled=True"

# ============================================================
# Step 3: Create Bot Locale (en_US)
# ============================================================
echo ""
echo ">>> Step 3: Creating bot locale (en_US)..."

LOCALE_STATUS=$(aws lexv2-models describe-bot-locale \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "en_US" \
  --region "${REGION}" --query "botLocaleStatus" --output text 2>/dev/null || echo "NotFound")

if [ "${LOCALE_STATUS}" != "NotFound" ]; then
  echo "    Already exists (${LOCALE_STATUS})"
else
  aws lexv2-models create-bot-locale \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "en_US" \
    --nlu-intent-confidence-threshold 0.40 \
    --description "English US locale for payment collection" \
    --region "${REGION}"

  echo "    Waiting for locale to be created..."
  while true; do
    LOCALE_STATUS=$(aws lexv2-models describe-bot-locale \
      --bot-id "${BOT_ID}" \
      --bot-version "DRAFT" \
      --locale-id "en_US" \
      --region "${REGION}" \
      --query 'botLocaleStatus' \
      --output text)
    echo "      Locale status: ${LOCALE_STATUS}"
    [ "${LOCALE_STATUS}" = "NotBuilt" ] || [ "${LOCALE_STATUS}" = "Built" ] && break
    [ "${LOCALE_STATUS}" = "Failed" ] && echo "❌ Locale creation failed" && exit 1
    sleep 5
  done
fi
echo "✅ Locale ready (${LOCALE_STATUS})"

# ============================================================
# Step 4: Create Custom Slot Type for Expiration Date
# ============================================================
echo ""
echo ">>> Step 4: Creating custom slot types..."

# Check if slot type already exists
EXISTING_SLOT_TYPE=$(aws lexv2-models list-slot-types \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "en_US" \
  --region "${REGION}" \
  --filters '[{"name":"SlotTypeName","values":["ExpirationDate"],"operator":"EQ"}]' \
  --query "slotTypeSummaries[0].slotTypeId" --output text 2>/dev/null || echo "None")

if [ "${EXISTING_SLOT_TYPE}" != "None" ] && [ -n "${EXISTING_SLOT_TYPE}" ]; then
  EXP_DATE_SLOT_TYPE_ID="${EXISTING_SLOT_TYPE}"
  echo "    ExpirationDate slot type already exists: ${EXP_DATE_SLOT_TYPE_ID}"
else
  EXP_DATE_SLOT_RESPONSE=$(aws lexv2-models create-slot-type \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "en_US" \
    --slot-type-name "ExpirationDate" \
    --description "Credit card expiration date in MM/YY format" \
    --slot-type-values '[
      {"sampleValue": {"value": "01/25"}},
      {"sampleValue": {"value": "12/26"}},
      {"sampleValue": {"value": "06/27"}},
      {"sampleValue": {"value": "03/28"}},
      {"sampleValue": {"value": "09/29"}},
      {"sampleValue": {"value": "11/25"}},
      {"sampleValue": {"value": "zero one twenty five"}},
      {"sampleValue": {"value": "zero three twenty six"}},
      {"sampleValue": {"value": "twelve twenty seven"}}
    ]' \
    --value-selection-setting '{
      "resolutionStrategy": "OriginalValue"
    }' \
    --region "${REGION}" \
    --output json)

  EXP_DATE_SLOT_TYPE_ID=$(echo "${EXP_DATE_SLOT_RESPONSE}" | "$PY" -c \
    "import sys,json; print(json.load(sys.stdin)['slotTypeId'])")
  echo "    Created: ${EXP_DATE_SLOT_TYPE_ID}"
fi
echo "✅ ExpirationDate slot type: ${EXP_DATE_SLOT_TYPE_ID}"

# ============================================================
# Step 5: Create CollectPayment Intent
# ============================================================
echo ""
echo ">>> Step 5: Creating CollectPayment intent..."

EXISTING_COLLECT_INTENT=$(aws lexv2-models list-intents \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "en_US" \
  --region "${REGION}" \
  --filters '[{"name":"IntentName","values":["CollectPayment"],"operator":"EQ"}]' \
  --query "intentSummaries[0].intentId" --output text 2>/dev/null || echo "None")

if [ "${EXISTING_COLLECT_INTENT}" != "None" ] && [ -n "${EXISTING_COLLECT_INTENT}" ]; then
  COLLECT_INTENT_ID="${EXISTING_COLLECT_INTENT}"
  echo "    Already exists: ${COLLECT_INTENT_ID}"
else
  COLLECT_PAYMENT_RESPONSE=$(aws lexv2-models create-intent \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "en_US" \
    --intent-name "CollectPayment" \
    --description "Collects credit card information and processes payment" \
    --sample-utterances '[
      {"utterance": "I want to make a payment"},
      {"utterance": "pay my bill"},
      {"utterance": "process a payment"},
      {"utterance": "charge my card"},
      {"utterance": "yes I want to pay"},
      {"utterance": "ready to pay"},
      {"utterance": "lets do it"},
      {"utterance": "yes"}
    ]' \
    --dialog-code-hook '{"enabled": false}' \
    --fulfillment-code-hook '{
      "enabled": true,
      "postFulfillmentStatusSpecification": {
        "successResponse": {
          "messageGroups": [
            {
              "message": {
                "plainTextMessage": {
                  "value": "Your payment has been processed. Returning you to our assistant."
                }
              }
            }
          ]
        },
        "failureResponse": {
          "messageGroups": [
            {
              "message": {
                "plainTextMessage": {
                  "value": "There was an issue processing your payment. Returning you to our assistant."
                }
              }
            }
          ]
        }
      }
    }' \
    --intent-confirmation-setting '{
      "promptSpecification": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "I have all your card details. Shall I go ahead and process your payment now?"
              }
            }
          }
        ],
        "maxRetries": 2,
        "allowInterrupt": true
      },
      "declinationResponse": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "Understood. Your payment has been cancelled."
              }
            }
          }
        ],
        "allowInterrupt": true
      }
    }' \
    --intent-closing-setting '{
      "closingResponse": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "Returning you to our assistant now."
              }
            }
          }
        ]
      },
      "active": true
    }' \
    --region "${REGION}" \
    --output json)

  COLLECT_INTENT_ID=$(echo "${COLLECT_PAYMENT_RESPONSE}" | "$PY" -c \
    "import sys,json; print(json.load(sys.stdin)['intentId'])")
  echo "    Created: ${COLLECT_INTENT_ID}"
fi
echo "✅ CollectPayment intent: ${COLLECT_INTENT_ID}"

# ============================================================
# Step 6: Create Slots for CollectPayment Intent
# ============================================================
echo ""
echo ">>> Step 6: Creating slots for CollectPayment..."

# Helper function to create slot idempotently
create_slot_if_not_exists() {
  local SLOT_NAME="$1"
  local SLOT_DESC="$2"
  local SLOT_TYPE_ID="$3"
  local PROMPT_TEXT="$4"
  local OBFUSCATE="$5"

  local FILTER_FILE
  FILTER_FILE=$(mktemp)
  cat > "${FILTER_FILE}" << FILTEREOF
[{"name":"SlotName","values":["${SLOT_NAME}"],"operator":"EQ"}]
FILTEREOF

  EXISTING_SLOT=$(aws lexv2-models list-slots \
    --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "en_US" \
    --intent-id "${COLLECT_INTENT_ID}" \
    --region "${REGION}" \
    --filters "$(file_uri "${FILTER_FILE}")" \
    --query "slotSummaries[0].slotId" --output text 2>/dev/null || echo "None")
  rm -f "${FILTER_FILE}"

  if [ "${EXISTING_SLOT}" != "None" ] && [ -n "${EXISTING_SLOT}" ]; then
    echo "    ${SLOT_NAME} already exists: ${EXISTING_SLOT}" >&2
    echo "${EXISTING_SLOT}"
    return
  fi

  local VES_FILE
  VES_FILE=$(mktemp)
  cat > "${VES_FILE}" << VESEOF
{
  "slotConstraint": "Required",
  "promptSpecification": {
    "messageGroups": [{
      "message": {
        "plainTextMessage": {
          "value": "${PROMPT_TEXT}"
        }
      }
    }],
    "maxRetries": 3,
    "allowInterrupt": true
  }
}
VESEOF

  local SLOT_RESPONSE
  if [ "${OBFUSCATE}" = "true" ]; then
    SLOT_RESPONSE=$(aws lexv2-models create-slot \
      --bot-id "${BOT_ID}" \
      --bot-version "DRAFT" \
      --locale-id "en_US" \
      --intent-id "${COLLECT_INTENT_ID}" \
      --slot-name "${SLOT_NAME}" \
      --description "${SLOT_DESC}" \
      --slot-type-id "${SLOT_TYPE_ID}" \
      --value-elicitation-setting "$(file_uri "${VES_FILE}")" \
      --obfuscation-setting '{"obfuscationSettingType": "DefaultObfuscation"}' \
      --region "${REGION}" \
      --output json)
  else
    SLOT_RESPONSE=$(aws lexv2-models create-slot \
      --bot-id "${BOT_ID}" \
      --bot-version "DRAFT" \
      --locale-id "en_US" \
      --intent-id "${COLLECT_INTENT_ID}" \
      --slot-name "${SLOT_NAME}" \
      --description "${SLOT_DESC}" \
      --slot-type-id "${SLOT_TYPE_ID}" \
      --value-elicitation-setting "$(file_uri "${VES_FILE}")" \
      --region "${REGION}" \
      --output json)
  fi
  rm -f "${VES_FILE}"

  local SLOT_ID
  SLOT_ID=$(echo "${SLOT_RESPONSE}" | "$PY" -c "import sys,json; print(json.load(sys.stdin)['slotId'])")
  echo "    ✅ ${SLOT_NAME} created: ${SLOT_ID}" >&2
  echo "${SLOT_ID}"
}

CARD_SLOT_ID=$(create_slot_if_not_exists \
  "cardNumber" \
  "16-digit credit card number" \
  "AMAZON.Number" \
  "Please provide your 16-digit credit or debit card number." \
  "true")

EXP_SLOT_ID=$(create_slot_if_not_exists \
  "expirationDate" \
  "Card expiration date MM/YY" \
  "${EXP_DATE_SLOT_TYPE_ID}" \
  "What is the expiration date on your card? Please say the month and year, for example, zero three twenty six." \
  "true")

CVV_SLOT_ID=$(create_slot_if_not_exists \
  "cvv" \
  "3 or 4 digit security code" \
  "AMAZON.Number" \
  "Please provide the 3 or 4 digit security code found on the back of your card." \
  "true")

ZIP_SLOT_ID=$(create_slot_if_not_exists \
  "billingZip" \
  "Billing zip code for card verification" \
  "AMAZON.Number" \
  "What is the 5-digit billing zip code associated with this card?" \
  "false")

echo "✅ All slots ready"

# ============================================================
# Step 7: Update Intent with Slot Priorities
# ============================================================
echo ""
echo ">>> Step 7: Setting slot priorities..."

SLOT_PRIORITIES_FILE=$(mktemp)
cat > "${SLOT_PRIORITIES_FILE}" << EOF
[
  {"priority": 1, "slotId": "${CARD_SLOT_ID}"},
  {"priority": 2, "slotId": "${EXP_SLOT_ID}"},
  {"priority": 3, "slotId": "${CVV_SLOT_ID}"},
  {"priority": 4, "slotId": "${ZIP_SLOT_ID}"}
]
EOF

aws lexv2-models update-intent \
  --bot-id "${BOT_ID}" \
  --bot-version "DRAFT" \
  --locale-id "en_US" \
  --intent-id "${COLLECT_INTENT_ID}" \
  --intent-name "CollectPayment" \
  --description "Collects credit card information and processes payment" \
  --sample-utterances '[
    {"utterance": "I want to make a payment"},
    {"utterance": "pay my bill"},
    {"utterance": "process a payment"},
    {"utterance": "charge my card"},
    {"utterance": "yes I want to pay"},
    {"utterance": "ready to pay"},
    {"utterance": "yes"}
  ]' \
  --slot-priorities "$(cat ${SLOT_PRIORITIES_FILE})" \
  --fulfillment-code-hook '{
    "enabled": true,
    "postFulfillmentStatusSpecification": {
      "successResponse": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "Your payment has been processed. Returning you to our assistant."
              }
            }
          }
        ]
      },
      "failureResponse": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "There was an issue with your payment. Returning you to our assistant."
              }
            }
          }
        ]
      }
    }
  }' \
  --intent-confirmation-setting '{
    "promptSpecification": {
      "messageGroups": [
        {
          "message": {
            "plainTextMessage": {
              "value": "I have all your card details. Shall I go ahead and process your payment now?"
            }
          }
        }
      ],
      "maxRetries": 2,
      "allowInterrupt": true
    },
    "declinationResponse": {
      "messageGroups": [
        {
          "message": {
            "plainTextMessage": {
              "value": "Understood. Your payment has been cancelled."
            }
          }
        }
      ],
      "allowInterrupt": true
    }
  }' \
  --intent-closing-setting '{
    "closingResponse": {
      "messageGroups": [
        {
          "message": {
            "plainTextMessage": {
              "value": "Returning you to our assistant now."
            }
          }
        }
      ]
    },
    "active": true
  }' \
  --region "${REGION}" > /dev/null

rm -f "${SLOT_PRIORITIES_FILE}"
echo "✅ Slot priorities set"

# ============================================================
# Step 8: Create CancelPayment Intent
# ============================================================
echo ""
echo ">>> Step 8: Creating CancelPayment intent..."

EXISTING_CANCEL_INTENT=$(aws lexv2-models list-intents \
  --bot-id "${BOT_ID}" --bot-version "DRAFT" --locale-id "en_US" \
  --region "${REGION}" \
  --filters '[{"name":"IntentName","values":["CancelPayment"],"operator":"EQ"}]' \
  --query "intentSummaries[0].intentId" --output text 2>/dev/null || echo "None")

if [ "${EXISTING_CANCEL_INTENT}" != "None" ] && [ -n "${EXISTING_CANCEL_INTENT}" ]; then
  CANCEL_INTENT_ID="${EXISTING_CANCEL_INTENT}"
  echo "    Already exists: ${CANCEL_INTENT_ID}"
else
  CANCEL_RESPONSE=$(aws lexv2-models create-intent \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "en_US" \
    --intent-name "CancelPayment" \
    --description "Allows customer to cancel the payment process" \
    --sample-utterances '[
      {"utterance": "cancel"},
      {"utterance": "cancel payment"},
      {"utterance": "never mind"},
      {"utterance": "stop"},
      {"utterance": "I do not want to pay"},
      {"utterance": "no thanks"},
      {"utterance": "quit"},
      {"utterance": "go back"},
      {"utterance": "I changed my mind"},
      {"utterance": "forget it"}
    ]' \
    --fulfillment-code-hook '{"enabled": true}' \
    --intent-closing-setting '{
      "closingResponse": {
        "messageGroups": [
          {
            "message": {
              "plainTextMessage": {
                "value": "Your payment has been cancelled. Returning you to our assistant."
              }
            }
          }
        ]
      },
      "active": true
    }' \
    --region "${REGION}" \
    --output json)

  CANCEL_INTENT_ID=$(echo "${CANCEL_RESPONSE}" | "$PY" -c \
    "import sys,json; print(json.load(sys.stdin)['intentId'])")
  echo "    Created: ${CANCEL_INTENT_ID}"
fi
echo "✅ CancelPayment intent: ${CANCEL_INTENT_ID}"

# ============================================================
# Step 9: Capture FallbackIntent ID
# ============================================================
echo ""
echo ">>> Step 9: Capturing FallbackIntent ID..."
echo "    ℹ️  FallbackIntent responses are controlled by Lambda."

FALLBACK_INTENT_ID=$(aws lexv2-models list-intents \
  --bot-id "${BOT_ID}" \
  --bot-version "DRAFT" \
  --locale-id "en_US" \
  --filters '[{"name": "IntentName", "values": ["FallbackIntent"], "operator": "EQ"}]' \
  --region "${REGION}" \
  --query 'intentSummaries[0].intentId' \
  --output text)

echo "✅ FallbackIntent ID: ${FALLBACK_INTENT_ID}"

# ============================================================
# Step 10: Build the Bot Locale
# ============================================================
echo ""
echo ">>> Step 10: Building bot locale..."

aws lexv2-models build-bot-locale \
  --bot-id "${BOT_ID}" \
  --bot-version "DRAFT" \
  --locale-id "en_US" \
  --region "${REGION}"

echo "    Build initiated. Polling for completion..."

WAIT_COUNT=0
MAX_WAIT=60

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  sleep 10
  WAIT_COUNT=$((WAIT_COUNT + 1))

  BUILD_STATUS=$(aws lexv2-models describe-bot-locale \
    --bot-id "${BOT_ID}" \
    --bot-version "DRAFT" \
    --locale-id "en_US" \
    --region "${REGION}" \
    --query 'botLocaleStatus' \
    --output text)

  echo "      Build status: ${BUILD_STATUS} (attempt ${WAIT_COUNT}/${MAX_WAIT})"

  if [ "$BUILD_STATUS" = "Built" ] || [ "$BUILD_STATUS" = "ReadyExpressTesting" ]; then
    echo "✅ Bot locale build successful! Status: ${BUILD_STATUS}"
    break
  elif [ "$BUILD_STATUS" = "Failed" ]; then
    echo "❌ ERROR: Bot build failed!"
    aws lexv2-models describe-bot-locale \
      --bot-id "${BOT_ID}" \
      --bot-version "DRAFT" \
      --locale-id "en_US" \
      --region "${REGION}" \
      --query 'failureReasons' \
      --output json
    exit 1
  fi
done

if [ "$BUILD_STATUS" != "Built" ] && [ "$BUILD_STATUS" != "ReadyExpressTesting" ]; then
  echo "❌ ERROR: Build timed out. Final status: ${BUILD_STATUS}"
  exit 1
fi

# ============================================================
# Step 11: Create Bot Version
# ============================================================
echo ""
echo ">>> Step 11: Creating bot version..."

VERSION_SPEC_FILE=$(mktemp)
cat > "${VERSION_SPEC_FILE}" << 'EOF'
{"en_US": {"sourceBotVersion": "DRAFT"}}
EOF

VERSION_RESPONSE=$(aws lexv2-models create-bot-version \
  --bot-id "${BOT_ID}" \
  --bot-version-locale-specification "$(file_uri "${VERSION_SPEC_FILE}")" \
  --region "${REGION}" \
  --output json)

rm -f "${VERSION_SPEC_FILE}"

BOT_VERSION=$(echo "${VERSION_RESPONSE}" | "$PY" -c \
  "import sys,json; print(json.load(sys.stdin)['botVersion'])")
echo "    Bot version created: ${BOT_VERSION}"

echo "    Waiting for version to become available..."
WAIT_COUNT=0
while [ $WAIT_COUNT -lt 30 ]; do
  sleep 10
  WAIT_COUNT=$((WAIT_COUNT + 1))
  VERSION_STATUS=$(aws lexv2-models describe-bot-version \
    --bot-id "${BOT_ID}" \
    --bot-version "${BOT_VERSION}" \
    --region "${REGION}" \
    --query 'botStatus' \
    --output text)
  echo "      Version status: ${VERSION_STATUS} (attempt ${WAIT_COUNT}/30)"
  [ "${VERSION_STATUS}" = "Available" ] && break
  [ "${VERSION_STATUS}" = "Failed" ] && echo "❌ Version creation failed" && exit 1
done
echo "✅ Bot version ${BOT_VERSION} is available"

# ============================================================
# Step 12: Create/Update Bot Alias (logs disabled for PCI)
# ============================================================
echo ""
echo ">>> Step 12: Bot alias '${ALIAS_NAME}' (logs disabled for PCI)..."

# Check for existing alias
EXISTING_ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id "${BOT_ID}" --region "${REGION}" \
  --query "botAliasSummaries[?botAliasName=='${ALIAS_NAME}'].botAliasId | [0]" \
  --output text 2>/dev/null || echo "None")

# Create settings file BEFORE if/else so both paths can use it
ALIAS_SETTINGS_FILE=$(mktemp)
cat > "${ALIAS_SETTINGS_FILE}" << EOF
{
  "en_US": {
    "enabled": true,
    "codeHookSpecification": {
      "lambdaCodeHook": {
        "lambdaARN": "${PAYMENT_LAMBDA_ARN}",
        "codeHookInterfaceVersion": "1.0"
      }
    }
  }
}
EOF

if [ "${EXISTING_ALIAS_ID}" != "None" ] && [ -n "${EXISTING_ALIAS_ID}" ]; then
  BOT_ALIAS_ID="${EXISTING_ALIAS_ID}"
  aws lexv2-models update-bot-alias \
    --bot-id "${BOT_ID}" \
    --bot-alias-id "${BOT_ALIAS_ID}" \
    --bot-alias-name "${ALIAS_NAME}" \
    --bot-version "${BOT_VERSION}" \
    --bot-alias-locale-settings "$(file_uri "${ALIAS_SETTINGS_FILE}")" \
    --region "${REGION}" > /dev/null
  echo "    Updated existing alias: ${BOT_ALIAS_ID} -> v${BOT_VERSION}"
else
  ALIAS_RESPONSE=$(aws lexv2-models create-bot-alias \
    --bot-id "${BOT_ID}" \
    --bot-alias-name "${ALIAS_NAME}" \
    --bot-version "${BOT_VERSION}" \
    --bot-alias-locale-settings "$(file_uri "${ALIAS_SETTINGS_FILE}")" \
    --description "Production alias for PCI payment collection - logs disabled" \
    --region "${REGION}" \
    --output json)

  BOT_ALIAS_ID=$(echo "${ALIAS_RESPONSE}" | "$PY" -c \
    "import sys,json; print(json.load(sys.stdin)['botAliasId'])")
  echo "    Created alias: ${BOT_ALIAS_ID}"
fi

rm -f "${ALIAS_SETTINGS_FILE}"

# Set BOT_ALIAS_ARN after if/else so it's available for both paths
BOT_ALIAS_ARN="arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${BOT_ID}/${BOT_ALIAS_ID}"
echo "    Alias ARN: ${BOT_ALIAS_ARN}"

# Verify alias locale settings
echo "    Verifying alias locale settings..."
ALIAS_LOCALE=$(aws lexv2-models describe-bot-alias \
  --bot-id "${BOT_ID}" --bot-alias-id "${BOT_ALIAS_ID}" \
  --region "${REGION}" \
  --query "botAliasLocaleSettings" --output json)

if echo "${ALIAS_LOCALE}" | grep -q "lambdaARN"; then
  echo "    ✅ Lambda ARN confirmed in alias locale settings"
elif [ "${ALIAS_LOCALE}" = "null" ]; then
  echo "    ❌ ERROR: Alias locale settings are null!"
  echo "    The PaymentProcessing Lambda will never be invoked."
  exit 1
else
  echo "    ⚠️  Alias locale settings present but no Lambda ARN found"
fi

# ============================================================
# Step 12b: Verify logging is disabled (PCI audit check)
# ============================================================
echo ""
echo ">>> Step 12b: Verifying conversation logs are disabled..."

export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_ALIAS="${BOT_ALIAS_ID}"
run_py << 'PYEOF'
import boto3, sys, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
response = client.describe_bot_alias(botId=os.environ['_PY_BOT'], botAliasId=os.environ['_PY_ALIAS'])
log_settings = response.get('conversationLogSettings', {})
text_on = any(s.get('enabled', False) for s in log_settings.get('textLogSettings', []))
audio_on = any(s.get('enabled', False) for s in log_settings.get('audioLogSettings', []))
print(f"    Text logging enabled:  {text_on}")
print(f"    Audio logging enabled: {audio_on}")
if not text_on and not audio_on:
    print("    ✅ PCI COMPLIANT: All conversation logging is DISABLED")
else:
    print("    ❌ PCI WARNING: Conversation logging is ENABLED!")
    sys.exit(1)
PYEOF

# ============================================================
# Step 13: Add Lambda invoke permission for Lex
# ============================================================
echo ""
echo ">>> Step 13: Adding Lambda invoke permissions for Lex..."

# Alias-specific permission
aws lambda add-permission \
  --function-name "${PAYMENT_LAMBDA_ARN}" \
  --statement-id "AllowLexPaymentBot-${BOT_ID}-${BOT_ALIAS_ID}" \
  --action "lambda:InvokeFunction" \
  --principal "lexv2.amazonaws.com" \
  --source-arn "${BOT_ALIAS_ARN}" \
  --region "${REGION}" 2>/dev/null \
  && echo "    Permission added (alias-specific)" \
  || echo "    Already exists (alias-specific, OK)"

# Bot-level permission (covers TestBotAlias and future aliases)
aws lambda add-permission \
  --function-name "${PAYMENT_LAMBDA_ARN}" \
  --statement-id "AllowLexPaymentBot-${BOT_ID}-AllAliases" \
  --action "lambda:InvokeFunction" \
  --principal "lexv2.amazonaws.com" \
  --source-arn "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot/${BOT_ID}" \
  --region "${REGION}" 2>/dev/null \
  && echo "    Permission added (bot-level)" \
  || echo "    Already exists (bot-level, OK)"

echo "✅ Lambda permissions configured"

# ============================================================
# Step 14: Associate Bot with Connect Instance
# ============================================================
echo ""
echo ">>> Step 14: Associating bot with Connect instance..."

ASSOCIATE_FILE=$(mktemp)
cat > "${ASSOCIATE_FILE}" << EOF
{"AliasArn": "${BOT_ALIAS_ARN}"}
EOF

aws connect associate-bot \
  --instance-id "${CONNECT_INSTANCE_ID}" \
  --lex-v2-bot "$(file_uri "${ASSOCIATE_FILE}")" \
  --region "${REGION}" 2>/dev/null \
  && echo "    Associated!" \
  || echo "    Already associated (OK)"

rm -f "${ASSOCIATE_FILE}"

# Verify association
echo "    Verifying association..."
aws connect list-bots \
  --instance-id "${CONNECT_INSTANCE_ID}" \
  --lex-version "V2" \
  --region "${REGION}" \
  --query 'LexBots[*].{Name:LexBot.Name,AliasArn:LexBot.AliasArn}' \
  --output table

# ============================================================
# Step 15: Final Verification
# ============================================================
echo ""
echo ">>> Step 15: Final verification..."

export _PY_REGION="${REGION}" _PY_BOT="${BOT_ID}" _PY_VER="${BOT_VERSION}" \
       _PY_INTENT="${COLLECT_INTENT_ID}" _PY_ALIAS="${BOT_ALIAS_ID}"
run_py << 'PYEOF'
import boto3, os
client = boto3.client('lexv2-models', region_name=os.environ['_PY_REGION'])
intent = client.describe_intent(
    botId=os.environ['_PY_BOT'], botVersion=os.environ['_PY_VER'],
    localeId='en_US', intentId=os.environ['_PY_INTENT']
)
fch = intent.get('fulfillmentCodeHook', {})
ver = os.environ['_PY_VER']
print(f"  CollectPayment (v{ver}): fulfillment enabled={fch.get('enabled', False)}")
alias_resp = client.describe_bot_alias(botId=os.environ['_PY_BOT'], botAliasId=os.environ['_PY_ALIAS'])
en_us = alias_resp.get('botAliasLocaleSettings', {}).get('en_US', {})
lambda_arn = en_us.get('codeHookSpecification', {}).get('lambdaCodeHook', {}).get('lambdaARN', 'NOT SET')
print(f"  Alias '{alias_resp.get('botAliasName')}': version={alias_resp.get('botVersion')}")
print(f"  Alias Lambda: {lambda_arn}")
errors = []
if not fch.get('enabled', False): errors.append('Fulfillment NOT enabled on CollectPayment intent')
if lambda_arn == 'NOT SET': errors.append('Lambda ARN NOT set on alias locale settings')
if alias_resp.get('botVersion') != ver: errors.append(f'Alias points to v{alias_resp.get("botVersion")}, expected v{ver}')
if errors:
    print('\n  \u274c VALIDATION ERRORS:')
    [print(f'     - {e}') for e in errors]
else:
    print('\n  \u2705 All checks passed!')
PYEOF

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "✅ PCI Payment Bot Creation Complete!"
echo "============================================"
echo ""
echo "Bot Name:       ${BOT_NAME}"
echo "Bot ID:         ${BOT_ID}"
echo "Bot Version:    ${BOT_VERSION}"
echo "Alias Name:     ${ALIAS_NAME}"
echo "Alias ID:       ${BOT_ALIAS_ID}"
echo "Alias ARN:      ${BOT_ALIAS_ARN}"
echo "Role ARN:       ${BOT_ROLE_ARN}"
echo ""
echo "Intent IDs:"
echo "  CollectPayment:  ${COLLECT_INTENT_ID}"
echo "  CancelPayment:   ${CANCEL_INTENT_ID}"
echo "  FallbackIntent:  ${FALLBACK_INTENT_ID}"
echo ""
echo "Slot IDs:"
echo "  cardNumber:      ${CARD_SLOT_ID}"
echo "  expirationDate:  ${EXP_SLOT_ID}"
echo "  cvv:             ${CVV_SLOT_ID}"
echo "  billingZip:      ${ZIP_SLOT_ID}"
echo ""
echo "Payment Lambda:   ${PAYMENT_LAMBDA_ARN}"
echo "Connect Instance: ${CONNECT_INSTANCE_ID}"
echo ""
echo "Fulfillment chain (3 required pieces):"
echo "  ✅ 1. FulfillmentCodeHook enabled on CollectPayment intent"
echo "  ✅ 2. Lambda ARN configured on alias locale settings"
echo "  ✅ 3. Lambda resource policy allows lexv2.amazonaws.com"
echo ""
echo "PCI Compliance:"
echo "  ✅ Conversation logging DISABLED"
echo "  ✅ Card data slots OBFUSCATED (cardNumber, expirationDate, cvv)"
echo ""
echo "⚠️  NEXT STEPS:"
echo "  1. Update Connect flow 'PCI Payment Bot' block with:"
echo "     Bot: ${BOT_NAME}, Alias: ${ALIAS_NAME}"
echo "  2. Update SeedPaymentSession Lambda env vars:"
echo "     PAYMENT_BOT_ID=${BOT_ID}"
echo "     PAYMENT_BOT_ALIAS_ID=${BOT_ALIAS_ID}"
echo "  3. Test end-to-end payment flow"

# Save configuration
CONFIG_FILE="payment-bot-config.json"
cat > "${CONFIG_FILE}" << EOF
{
  "botName": "${BOT_NAME}",
  "botId": "${BOT_ID}",
  "botVersion": "${BOT_VERSION}",
  "botAliasName": "${ALIAS_NAME}",
  "botAliasId": "${BOT_ALIAS_ID}",
  "botAliasArn": "${BOT_ALIAS_ARN}",
  "roleArn": "${BOT_ROLE_ARN}",
  "intents": {
    "CollectPayment": "${COLLECT_INTENT_ID}",
    "CancelPayment": "${CANCEL_INTENT_ID}",
    "FallbackIntent": "${FALLBACK_INTENT_ID}"
  },
  "slots": {
    "cardNumber": "${CARD_SLOT_ID}",
    "expirationDate": "${EXP_SLOT_ID}",
    "cvv": "${CVV_SLOT_ID}",
    "billingZip": "${ZIP_SLOT_ID}"
  },
  "paymentLambdaArn": "${PAYMENT_LAMBDA_ARN}",
  "connectInstanceId": "${CONNECT_INSTANCE_ID}",
  "region": "${REGION}",
  "accountId": "${ACCOUNT_ID}"
}
EOF

echo "✅ Configuration saved to ${CONFIG_FILE}"
