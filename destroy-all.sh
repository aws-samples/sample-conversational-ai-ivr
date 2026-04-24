#!/usr/bin/env bash
###############################################################################
#  destroy-all.sh — Complete teardown of AnyCompany IVR solution
#
#  Destroys ALL resources in reverse dependency order:
#    Phase 0:  Release phone numbers
#    Phase 1:  Disassociate & delete Lex Bots
#    Phase 2:  Clean up Q in Connect (AI Agents, Prompts, KB)
#    Phase 3:  Clean up Lambda resource policies
#    Phase 4:  Delete CloudFormation stacks (reverse order)
#    Phase 5:  Clean up S3 buckets
#    Phase 6:  Clean up CloudWatch log groups
#    Phase 7:  Clean up App Integrations
#    Phase 8:  Verification
#
#  Prerequisites:
#    - source env.sh (same env.sh used by deploy-all.sh)
#    - AWS CLI configured with appropriate permissions
#    - Python 3 with boto3 installed
#
#  Usage:
#    source env.sh
#    ./destroy-all.sh
#
#  ⚠️  WARNING: This is DESTRUCTIVE and IRREVERSIBLE!
###############################################################################

set -euo pipefail

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONLEGACYWINDOWSSTDIO=0

# Cross-platform temp directory
TMP_DIR="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
TMP_DIR="${TMP_DIR%/}"

# ============================================================
# Source environment — same env.sh used by deploy-all.sh
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/env.sh" ]; then
  source "${SCRIPT_DIR}/env.sh"
elif [ -f "./env.sh" ]; then
  source ./env.sh
else
  echo "ERROR: env.sh not found. Source it before running or place it alongside this script."
  exit 1
fi

# ============================================================
# Required Variables from env.sh
# ============================================================
REGION="${REGION:?ERROR: export REGION before running (e.g., us-east-1)}"
STACK_NAME="${STACK_NAME:?ERROR: export STACK_NAME before running (e.g., anycompany-ivr)}"
BUCKET="${BUCKET:?ERROR: export BUCKET before running (S3 bucket for templates)}"
OPENAPI_BUCKET="${OPENAPI_BUCKET:?ERROR: export OPENAPI_BUCKET before running}"
KB_BUCKET="${KB_BUCKET:?ERROR: export KB_BUCKET before running}"

# ============================================================
# Optional Variables
# ============================================================
ENVIRONMENT="${ENVIRONMENT:-dev}"
PHASE2_STACK_NAME="${PHASE2_STACK_NAME:-${STACK_NAME}-phase2-qagents}"
PREFIX="${PREFIX:-${STACK_NAME}/templates}"

# ============================================================
# Detect Python with boto3
# ============================================================
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

# Helper: write stdin to temp file and run with resolved $PY
run_py() {
  local _f
  _f=$(mktemp "${TMP_DIR}/destroy_XXXXXX.py")
  cat > "$_f"
  "$PY" "$_f"
  local rc=$?
  rm -f "$_f"
  return $rc
}

# ============================================================
# Derive Account ID
# ============================================================
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ============================================================
# Cross-platform color support
# ============================================================
if [[ "${TERM:-}" == "dumb" ]] || [[ "${NO_COLOR:-}" == "1" ]]; then
  RED='' GREEN='' YELLOW='' CYAN='' NC=''
else
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  NC='\033[0m'
fi

# ============================================================
# Helper Functions
# ============================================================

log_header() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  $1${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
}

log_step() {
  echo -e "  ${YELLOW}>>>  $1${NC}"
}

log_ok() {
  echo -e "  ${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "  ${YELLOW}⚠️  $1${NC}"
}

log_err() {
  echo -e "  ${RED}❌ $1${NC}"
}

log_skip() {
  echo -e "  ${YELLOW}⏭️  $1${NC}"
}

# Get a CloudFormation output value (returns empty string on failure)
get_output_safe() {
  local stack="$1"
  local key="$2"
  aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

# Get nested stack physical resource ID
get_nested_stack_id_safe() {
  local logical_id="$1"
  aws cloudformation describe-stack-resources \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --logical-resource-id "$logical_id" \
    --query "StackResources[0].PhysicalResourceId" \
    --output text 2>/dev/null || echo ""
}

# Check if a CFN stack exists and is not DELETE_COMPLETE
stack_exists() {
  local stack_name="$1"
  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null) || return 1
  [ "$status" != "DELETE_COMPLETE" ]
}

wait_for_stack_delete() {
  local stack_name="$1"
  local max_wait=300
  local elapsed=0
  local interval=10

  while [ $elapsed -lt $max_wait ]; do
    local status
    status=$(aws cloudformation describe-stacks \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --query "Stacks[0].StackStatus" \
      --output text 2>/dev/null) || {
      log_ok "$stack_name deleted"
      return 0
    }

    if [ "$status" = "DELETE_COMPLETE" ]; then
      log_ok "$stack_name deleted"
      return 0
    fi

    if [ "$status" = "DELETE_FAILED" ]; then
      log_err "$stack_name DELETE_FAILED"
      return 1
    fi

    echo -e "    Waiting... ($status) ${elapsed}s"
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  log_err "$stack_name delete timed out after ${max_wait}s"
  return 1
}

# ============================================================
# Discover Resource IDs from CloudFormation
# ============================================================
log_header "Discovering deployed resources..."

echo ""
log_step "Looking up Connect Instance..."
CONNECT_INSTANCE_ID=""
CONNECT_INSTANCE_ARN=""
ASSISTANT_ID=""
ASSISTANT_ARN=""

if stack_exists "$STACK_NAME"; then
  # Get Connect Instance from nested stack
  CONNECT_STACK_ID=$(get_nested_stack_id_safe "ConnectInstanceStack")
  if [ -n "$CONNECT_STACK_ID" ] && [ "$CONNECT_STACK_ID" != "None" ]; then
    CONNECT_INSTANCE_ARN=$(get_output_safe "$CONNECT_STACK_ID" "ConnectInstanceArn")
    CONNECT_INSTANCE_ID=$(get_output_safe "$CONNECT_STACK_ID" "ConnectInstanceId")
  fi

  # Fallback: try root stack output
  if [ -z "$CONNECT_INSTANCE_ARN" ] || [ "$CONNECT_INSTANCE_ARN" = "None" ]; then
    CONNECT_INSTANCE_ARN=$(get_output_safe "$STACK_NAME" "ConnectInstanceArn")
    if [ -n "$CONNECT_INSTANCE_ARN" ] && [ "$CONNECT_INSTANCE_ARN" != "None" ]; then
      CONNECT_INSTANCE_ID=$(echo "$CONNECT_INSTANCE_ARN" | awk -F'instance/' '{print $2}')
    fi
  fi

  # Get Q in Connect Assistant
  CONFIG_STACK_ID=$(get_nested_stack_id_safe "ConnectConfigStack")
  if [ -n "$CONFIG_STACK_ID" ] && [ "$CONFIG_STACK_ID" != "None" ]; then
    ASSISTANT_ID=$(get_output_safe "$CONFIG_STACK_ID" "QInConnectAssistantId")
    ASSISTANT_ARN=$(get_output_safe "$CONFIG_STACK_ID" "QInConnectAssistantArn")
  fi

  echo "  Connect Instance ID:  ${CONNECT_INSTANCE_ID:-NOT FOUND}"
  echo "  Connect Instance ARN: ${CONNECT_INSTANCE_ARN:-NOT FOUND}"
  echo "  Q Assistant ID:       ${ASSISTANT_ID:-NOT FOUND}"
  echo "  Q Assistant ARN:      ${ASSISTANT_ARN:-NOT FOUND}"
else
  log_warn "Root stack $STACK_NAME not found — some resources may need manual cleanup"
fi

# ────────────────────────────────────────────────────
# Discover Lex Bots by name
# ────────────────────────────────────────────────────
log_step "Looking up Lex Bots..."

discover_bot() {
  local bot_name="$1"
  local bot_id=""
  local alias_id=""

  bot_id=$(aws lexv2-models list-bots \
    --region "$REGION" \
    --filters name=BotName,values="${bot_name}",operator=EQ \
    --query "botSummaries[0].botId" --output text 2>/dev/null || echo "None")

  if [ "$bot_id" != "None" ] && [ -n "$bot_id" ]; then
    alias_id=$(aws lexv2-models list-bot-aliases \
      --bot-id "$bot_id" \
      --region "$REGION" \
      --query "botAliasSummaries[?botAliasName=='live'].botAliasId | [0]" \
      --output text 2>/dev/null || echo "None")
  else
    bot_id=""
  fi

  [ "$alias_id" = "None" ] && alias_id=""

  echo "${bot_id}|${alias_id}"
}

PARK_BOT_RESULT=$(discover_bot "ParkAndTollBot")
PARK_AND_TOLL_BOT_ID=$(echo "$PARK_BOT_RESULT" | cut -d'|' -f1)
PARK_AND_TOLL_ALIAS_ID=$(echo "$PARK_BOT_RESULT" | cut -d'|' -f2)

PAYMENT_BOT_RESULT=$(discover_bot "PaymentCollectionBot")
PAYMENT_BOT_ID=$(echo "$PAYMENT_BOT_RESULT" | cut -d'|' -f1)
PAYMENT_BOT_ALIAS_ID=$(echo "$PAYMENT_BOT_RESULT" | cut -d'|' -f2)

echo "  ParkAndTollBot:       ID=${PARK_AND_TOLL_BOT_ID:-NOT FOUND}  Alias=${PARK_AND_TOLL_ALIAS_ID:-NOT FOUND}"
echo "  PaymentCollectionBot: ID=${PAYMENT_BOT_ID:-NOT FOUND}  Alias=${PAYMENT_BOT_ALIAS_ID:-NOT FOUND}"

# ────────────────────────────────────────────────────
# Discover Lambda function names from stacks
# ────────────────────────────────────────────────────
log_step "Looking up Lambda functions..."

FULFILLMENT_LAMBDA=""
if stack_exists "${STACK_NAME}-fulfillment-hook"; then
  FULFILLMENT_LAMBDA=$(get_output_safe "${STACK_NAME}-fulfillment-hook" "FulfillmentHookFunctionName")
fi
# Fallback: try common name pattern
if [ -z "$FULFILLMENT_LAMBDA" ] || [ "$FULFILLMENT_LAMBDA" = "None" ]; then
  FULFILLMENT_LAMBDA=$(aws lambda list-functions --region "$REGION" \
    --query "Functions[?contains(FunctionName,'QinConnectDialogHook') || contains(FunctionName,'DialogHook')].FunctionName | [0]" \
    --output text 2>/dev/null || echo "")
  [ "$FULFILLMENT_LAMBDA" = "None" ] && FULFILLMENT_LAMBDA=""
fi

PAYMENT_LAMBDA=""
if stack_exists "${STACK_NAME}-payment-handoff"; then
  PAYMENT_LAMBDA=$(get_output_safe "${STACK_NAME}-payment-handoff" "PaymentProcessingFunctionName")
fi
if [ -z "$PAYMENT_LAMBDA" ] || [ "$PAYMENT_LAMBDA" = "None" ]; then
  PAYMENT_LAMBDA=$(aws lambda list-functions --region "$REGION" \
    --query "Functions[?contains(FunctionName,'PaymentProcessing')].FunctionName | [0]" \
    --output text 2>/dev/null || echo "")
  [ "$PAYMENT_LAMBDA" = "None" ] && PAYMENT_LAMBDA=""
fi

echo "  Fulfillment Lambda: ${FULFILLMENT_LAMBDA:-NOT FOUND}"
echo "  Payment Lambda:     ${PAYMENT_LAMBDA:-NOT FOUND}"

# ────────────────────────────────────────────────────
# Build CloudFormation stack list (reverse of deploy order)
# ────────────────────────────────────────────────────
CFN_STACKS=(
  "${PHASE2_STACK_NAME}"
  "${STACK_NAME}-agent-screen-pop"
  "${STACK_NAME}-update-session"
  "${STACK_NAME}-payment-handoff"
  "${STACK_NAME}-api"
  "${STACK_NAME}-getCallAttributes"
  "${STACK_NAME}-fulfillment-hook"
  "${STACK_NAME}-payments-lambdas"
  "${STACK_NAME}-lambdas"
  "${STACK_NAME}-session-table"
  "${STACK_NAME}-dynamodb"
  "${STACK_NAME}-client-config"
  "${STACK_NAME}"
)

# ============================================================
# Summary & Confirmation
# ============================================================
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   ⚠️   COMPLETE DESTRUCTION OF ANYCOMPANY IVR   ⚠️      ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   This will permanently delete:                          ║${NC}"
echo -e "${RED}║   • Lex V2 bots (ParkAndTollBot, PaymentCollectionBot)  ║${NC}"
echo -e "${RED}║   • Q in Connect AI Agents, Prompts, KB associations    ║${NC}"
echo -e "${RED}║   • All ${#CFN_STACKS[@]} CloudFormation stacks                          ║${NC}"
echo -e "${RED}║   • Lambda functions, DynamoDB tables, API Gateway      ║${NC}"
echo -e "${RED}║   • Connect instance configuration                      ║${NC}"
echo -e "${RED}║   • S3 bucket contents                                  ║${NC}"
echo -e "${RED}║   • CloudWatch log groups                               ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   Account:  ${ACCOUNT_ID}                                ║${NC}"
echo -e "${RED}║   Region:   ${REGION}                                         ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -r -p "  Type 'DESTROY' to confirm: " CONFIRM

if [ "$CONFIRM" != "DESTROY" ]; then
  echo "  Aborted."
  exit 1
fi

echo ""
echo "  Starting destruction in 5 seconds... (Ctrl+C to cancel)"
sleep 5

# ═══════════════════════════════════════════════════════════════
#  PHASE 0: Release Phone Numbers
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 0: Release Phone Numbers"

if [ -n "$CONNECT_INSTANCE_ID" ] && [ "$CONNECT_INSTANCE_ID" != "None" ]; then
  log_step "Listing claimed phone numbers..."
  PHONE_NUMBERS=$(aws connect list-phone-numbers-v2 \
    --target-arn "arn:aws:connect:${REGION}:${ACCOUNT_ID}:instance/${CONNECT_INSTANCE_ID}" \
    --region "$REGION" \
    --query "ListPhoneNumbersSummaryList[*].PhoneNumberId" \
    --output text 2>/dev/null) || PHONE_NUMBERS=""

  if [ -n "$PHONE_NUMBERS" ] && [ "$PHONE_NUMBERS" != "None" ]; then
    for PHONE_ID in $PHONE_NUMBERS; do
      log_step "Releasing phone number: $PHONE_ID"
      aws connect release-phone-number \
        --phone-number-id "$PHONE_ID" \
        --region "$REGION" 2>/dev/null && \
        log_ok "Released $PHONE_ID" || \
        log_warn "Could not release $PHONE_ID"
    done
  else
    log_skip "No phone numbers to release"
  fi
else
  log_skip "Connect Instance not found — skipping phone number release"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 1: Disassociate & Delete Lex Bots
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 1: Disassociate & Delete Lex V2 Bots"

disassociate_bot_from_connect() {
  local bot_id="$1"
  local bot_name="$2"

  if [ -z "$CONNECT_INSTANCE_ID" ] || [ "$CONNECT_INSTANCE_ID" = "None" ]; then
    log_skip "No Connect instance — skipping disassociation for $bot_name"
    return 0
  fi

  if [ -z "$bot_id" ]; then
    log_skip "$bot_name not found — skipping disassociation"
    return 0
  fi

  log_step "Disassociating $bot_name ($bot_id) from Connect..."

  # Find the alias ARN associated with Connect
  ASSOC_ARN=$(aws connect list-bots \
    --instance-id "$CONNECT_INSTANCE_ID" \
    --lex-version V2 \
    --region "$REGION" \
    --query "LexBots[?LexBot.LexBotId=='${bot_id}'].LexBot.LexBotAliasArn | [0]" \
    --output text 2>/dev/null) || ASSOC_ARN=""

  if [ -n "$ASSOC_ARN" ] && [ "$ASSOC_ARN" != "None" ]; then
    aws connect disassociate-bot \
      --instance-id "$CONNECT_INSTANCE_ID" \
      --lex-bot "LexV2Bot={AliasArn=$ASSOC_ARN}" \
      --region "$REGION" 2>/dev/null && \
      log_ok "Disassociated $bot_name" || \
      log_warn "Could not disassociate $bot_name"
  else
    log_skip "$bot_name not associated with Connect"
  fi
}

delete_lex_bot() {
  local bot_id="$1"
  local bot_name="$2"
  local alias_id="$3"

  if [ -z "$bot_id" ]; then
    log_skip "$bot_name not found — nothing to delete"
    return 0
  fi

  log_step "Deleting $bot_name ($bot_id)..."

  # Verify bot exists
  aws lexv2-models describe-bot --bot-id "$bot_id" --region "$REGION" >/dev/null 2>&1 || {
    log_skip "$bot_name does not exist"
    return 0
  }

  # Delete alias (if not TSTALIASID)
  if [ -n "$alias_id" ] && [ "$alias_id" != "TSTALIASID" ]; then
    log_step "  Deleting alias $alias_id..."
    aws lexv2-models delete-bot-alias \
      --bot-id "$bot_id" \
      --bot-alias-id "$alias_id" \
      --skip-resource-in-use-check \
      --region "$REGION" 2>/dev/null && \
      log_ok "  Alias deleted" || \
      log_warn "  Could not delete alias"
    sleep 3
  fi

  # Delete all versions except DRAFT
  log_step "  Deleting bot versions..."
  VERSIONS=$(aws lexv2-models list-bot-versions \
    --bot-id "$bot_id" \
    --region "$REGION" \
    --query "botVersionSummaries[?botVersion!='DRAFT'].botVersion" \
    --output text 2>/dev/null) || VERSIONS=""

  if [ -n "$VERSIONS" ] && [ "$VERSIONS" != "None" ]; then
    for VER in $VERSIONS; do
      aws lexv2-models delete-bot-version \
        --bot-id "$bot_id" \
        --bot-version "$VER" \
        --skip-resource-in-use-check \
        --region "$REGION" 2>/dev/null && \
        echo "    Deleted version $VER" || true
    done
    sleep 2
  fi

  # Delete the bot
  log_step "  Deleting bot..."
  aws lexv2-models delete-bot \
    --bot-id "$bot_id" \
    --skip-resource-in-use-check \
    --region "$REGION" 2>/dev/null && \
    log_ok "$bot_name delete initiated" || \
    log_err "Could not delete $bot_name"

  # Wait for deletion
  local wait=0
  while [ $wait -lt 60 ]; do
    aws lexv2-models describe-bot --bot-id "$bot_id" --region "$REGION" >/dev/null 2>&1 || {
      log_ok "$bot_name fully removed"
      return 0
    }
    sleep 5
    wait=$((wait + 5))
    echo "    Waiting for bot deletion... ${wait}s"
  done

  log_warn "$bot_name may still be deleting"
}

# Disassociate both bots from Connect first
disassociate_bot_from_connect "$PARK_AND_TOLL_BOT_ID" "ParkAndTollBot"
disassociate_bot_from_connect "$PAYMENT_BOT_ID" "PaymentCollectionBot"

sleep 3

# Delete both bots
delete_lex_bot "$PARK_AND_TOLL_BOT_ID" "ParkAndTollBot" "$PARK_AND_TOLL_ALIAS_ID"
delete_lex_bot "$PAYMENT_BOT_ID" "PaymentCollectionBot" "$PAYMENT_BOT_ALIAS_ID"

# ═══════════════════════════════════════════════════════════════
#  PHASE 2: Clean up Q in Connect Resources
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 2: Clean up Q in Connect Resources"

if [ -n "$ASSISTANT_ID" ] && [ "$ASSISTANT_ID" != "None" ]; then
  log_step "Running Q in Connect cleanup via Python..."

  export _PY_REGION="$REGION" _PY_ASSISTANT_ID="$ASSISTANT_ID"

  run_py << 'PYEOF'
import boto3
import os
import time
import sys

region = os.environ['_PY_REGION']
assistant_id = os.environ['_PY_ASSISTANT_ID']

client = boto3.client('qconnect', region_name=region)

def safe_call(func, description, **kwargs):
    try:
        result = func(**kwargs)
        print(f"  ✅ {description}")
        return result
    except client.exceptions.ResourceNotFoundException:
        print(f"  ⏭️  {description} — not found, skipping")
        return None
    except client.exceptions.ConflictException as e:
        print(f"  ⚠️  {description} — conflict: {e}")
        return None
    except Exception as e:
        print(f"  ❌ {description} — error: {e}")
        return None

# Step 1: Remove AI Agent overrides from assistant
print("\n=== Step 1: Remove AI Agent overrides ===")
for agent_type in ['ORCHESTRATION', 'SELF_SERVICE']:
    safe_call(
        client.remove_assistant_ai_agent,
        f"Remove {agent_type} agent override",
        assistantId=assistant_id,
        aiAgentType=agent_type
    )
time.sleep(2)

# Step 2: Discover and delete all AI Agents
print("\n=== Step 2: Delete AI Agents ===")
try:
    agents = client.list_ai_agents(assistantId=assistant_id)
    for agent in agents.get('aiAgentSummaries', []):
        agent_id = agent.get('aiAgentId')
        agent_name = agent.get('name', 'unknown')
        print(f"\n  Processing agent: {agent_name} ({agent_id})")

        # Delete versions first
        try:
            versions = client.list_ai_agent_versions(
                assistantId=assistant_id, aiAgentId=agent_id
            )
            for v in versions.get('aiAgentVersionSummaries', []):
                vnum = v.get('versionNumber')
                if vnum:
                    safe_call(
                        client.delete_ai_agent_version,
                        f"Delete agent '{agent_name}' version {vnum}",
                        assistantId=assistant_id,
                        aiAgentId=agent_id,
                        versionNumber=vnum
                    )
                    time.sleep(1)
        except Exception as e:
            print(f"  ⚠️  Could not list versions for {agent_id}: {e}")

        time.sleep(2)
        safe_call(
            client.delete_ai_agent,
            f"Delete agent '{agent_name}' ({agent_id})",
            assistantId=assistant_id,
            aiAgentId=agent_id
        )
except Exception as e:
    print(f"  ⚠️  Could not list agents: {e}")

# Step 3: Delete all AI Prompts
print("\n=== Step 3: Delete AI Prompts ===")
try:
    prompts = client.list_ai_prompts(assistantId=assistant_id)
    for p in prompts.get('aiPromptSummaries', []):
        prompt_id = p.get('aiPromptId')
        prompt_name = p.get('name', 'unknown')

        # Delete versions first
        try:
            pversions = client.list_ai_prompt_versions(
                assistantId=assistant_id, aiPromptId=prompt_id
            )
            for pv in pversions.get('aiPromptVersionSummaries', []):
                pvnum = pv.get('versionNumber')
                if pvnum:
                    safe_call(
                        client.delete_ai_prompt_version,
                        f"Delete prompt '{prompt_name}' version {pvnum}",
                        assistantId=assistant_id,
                        aiPromptId=prompt_id,
                        versionNumber=pvnum
                    )
                    time.sleep(1)
        except Exception as e:
            print(f"  ⚠️  Could not list prompt versions: {e}")

        time.sleep(1)
        safe_call(
            client.delete_ai_prompt,
            f"Delete prompt '{prompt_name}' ({prompt_id})",
            assistantId=assistant_id,
            aiPromptId=prompt_id
        )
except Exception as e:
    print(f"  ⚠️  Could not list prompts: {e}")

# Step 4: Discover and delete KB associations and Knowledge Bases
print("\n=== Step 4: Delete KB associations ===")
try:
    associations = client.list_assistant_associations(assistantId=assistant_id)
    for assoc in associations.get('assistantAssociationSummaries', []):
        assoc_id = assoc.get('assistantAssociationId')
        assoc_type = assoc.get('associationType', 'unknown')
        kb_id_from_assoc = assoc.get('associationData', {}).get('knowledgeBaseAssociation', {}).get('knowledgeBaseId', '')

        safe_call(
            client.delete_assistant_association,
            f"Delete association {assoc_id} (type={assoc_type})",
            assistantId=assistant_id,
            assistantAssociationId=assoc_id
        )
        time.sleep(2)

        # Delete the KB itself
        if kb_id_from_assoc:
            # Delete KB contents first
            print(f"\n  Deleting contents from KB {kb_id_from_assoc}...")
            try:
                contents = client.list_contents(knowledgeBaseId=kb_id_from_assoc)
                for c in contents.get('contentSummaries', []):
                    content_id = c.get('contentId')
                    content_title = c.get('title', 'unknown')
                    safe_call(
                        client.delete_content,
                        f"Delete content '{content_title}'",
                        knowledgeBaseId=kb_id_from_assoc,
                        contentId=content_id
                    )
                    time.sleep(1)
            except Exception as e:
                print(f"  ⚠️  Could not list/delete contents: {e}")

            safe_call(
                client.delete_knowledge_base,
                f"Delete KB {kb_id_from_assoc}",
                knowledgeBaseId=kb_id_from_assoc
            )
except Exception as e:
    print(f"  ⚠️  Could not list associations: {e}")

# Step 5: Delete Assistant
print("\n=== Step 5: Delete Assistant ===")
time.sleep(3)
safe_call(
    client.delete_assistant,
    f"Delete assistant {assistant_id}",
    assistantId=assistant_id
)

print("\n=== Q in Connect cleanup complete ===")
PYEOF

  log_ok "Q in Connect cleanup finished"
else
  log_skip "No Q in Connect Assistant found — skipping"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 3: Clean up Lambda Resource Policies
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 3: Clean up Lambda Resource Policies"

remove_lambda_permissions() {
  local func_name="$1"

  if [ -z "$func_name" ] || [ "$func_name" = "None" ]; then
    return 0
  fi

  log_step "Cleaning permissions for $func_name..."

  # Check if function exists
  aws lambda get-function --function-name "$func_name" --region "$REGION" >/dev/null 2>&1 || {
    log_skip "$func_name does not exist"
    return 0
  }

  # Get all statement IDs from the policy
  POLICY=$(aws lambda get-policy --function-name "$func_name" --region "$REGION" 2>/dev/null) || {
    log_skip "No resource policy on $func_name"
    return 0
  }

  SIDS=$(echo "$POLICY" | "$PY" -c "
import sys, json
try:
    policy = json.loads(json.loads(sys.stdin.read())['Policy'])
    for stmt in policy.get('Statement', []):
        print(stmt['Sid'])
except: pass
" 2>/dev/null) || SIDS=""

  if [ -n "$SIDS" ]; then
    for SID in $SIDS; do
      aws lambda remove-permission \
        --function-name "$func_name" \
        --statement-id "$SID" \
        --region "$REGION" 2>/dev/null && \
        echo "    Removed: $SID" || true
    done
    log_ok "$func_name permissions cleaned"
  else
    log_skip "No permissions to remove from $func_name"
  fi
}

remove_lambda_permissions "$FULFILLMENT_LAMBDA"
remove_lambda_permissions "$PAYMENT_LAMBDA"

# Also clean up any Lambdas associated with Connect
if [ -n "$CONNECT_INSTANCE_ID" ] && [ "$CONNECT_INSTANCE_ID" != "None" ]; then
  log_step "Disassociating Lambdas from Connect instance..."

  ASSOCIATED_LAMBDAS=$(aws connect list-lambda-functions \
    --instance-id "$CONNECT_INSTANCE_ID" \
    --region "$REGION" \
    --query "LambdaFunctions" --output text 2>/dev/null) || ASSOCIATED_LAMBDAS=""

  if [ -n "$ASSOCIATED_LAMBDAS" ] && [ "$ASSOCIATED_LAMBDAS" != "None" ]; then
    for LAMBDA_ARN in $ASSOCIATED_LAMBDAS; do
      aws connect disassociate-lambda-function \
        --instance-id "$CONNECT_INSTANCE_ID" \
        --function-arn "$LAMBDA_ARN" \
        --region "$REGION" 2>/dev/null && \
        echo "    Disassociated: $(echo "$LAMBDA_ARN" | awk -F: '{print $NF}')" || true
    done
    log_ok "Lambda associations cleaned"
  else
    log_skip "No Lambdas associated with Connect"
  fi
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 4: Delete CloudFormation Stacks
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 4: Delete CloudFormation Stacks (${#CFN_STACKS[@]} stacks)"

for STACK in "${CFN_STACKS[@]}"; do
  echo ""
  log_step "Deleting stack: $STACK"

  # Check if stack exists
  STACK_STATUS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK" \
    --region "$REGION" \
    --query "Stacks[0].StackStatus" \
    --output text 2>/dev/null) || {
    log_skip "$STACK does not exist"
    continue
  }

  if [ "$STACK_STATUS" = "DELETE_COMPLETE" ]; then
    log_skip "$STACK already deleted"
    continue
  fi

  # If previous delete failed, retry with retain
  if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
    log_warn "$STACK in DELETE_FAILED state — retrying with retain..."

    FAILED_RESOURCES=$(aws cloudformation describe-stack-resources \
      --stack-name "$STACK" \
      --region "$REGION" \
      --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
      --output text 2>/dev/null) || FAILED_RESOURCES=""

    if [ -n "$FAILED_RESOURCES" ] && [ "$FAILED_RESOURCES" != "None" ]; then
      # Build retain args array
      RETAIN_ARGS=()
      for RES in $FAILED_RESOURCES; do
        RETAIN_ARGS+=("$RES")
      done
      aws cloudformation delete-stack \
        --stack-name "$STACK" \
        --retain-resources "${RETAIN_ARGS[@]}" \
        --region "$REGION" 2>/dev/null || true
    else
      aws cloudformation delete-stack \
        --stack-name "$STACK" \
        --region "$REGION" 2>/dev/null || true
    fi
  else
    # Normal delete
    aws cloudformation delete-stack \
      --stack-name "$STACK" \
      --region "$REGION" 2>/dev/null || {
      log_err "Could not initiate delete for $STACK"
      continue
    }
  fi

  wait_for_stack_delete "$STACK" || {
    log_err "$STACK failed to delete — may need manual intervention"
  }
done

# ═══════════════════════════════════════════════════════════════
#  PHASE 5: Clean up S3 Buckets
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 5: Clean up S3 Buckets"

empty_bucket() {
  local bucket_name="$1"

  log_step "Emptying bucket: $bucket_name"

  # Check if bucket exists
  aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null || {
    log_skip "Bucket $bucket_name does not exist"
    return 0
  }

  # Delete all object versions (handles versioned buckets)
  "$PY" -c "
import boto3, sys
s3 = boto3.client('s3', region_name='${REGION}')
paginator = s3.get_paginator('list_object_versions')
try:
    for page in paginator.paginate(Bucket='${bucket_name}'):
        objects = []
        for v in page.get('Versions', []):
            objects.append({'Key': v['Key'], 'VersionId': v['VersionId']})
        for d in page.get('DeleteMarkers', []):
            objects.append({'Key': d['Key'], 'VersionId': d['VersionId']})
        if objects:
            # Delete in batches of 1000
            for i in range(0, len(objects), 1000):
                batch = objects[i:i+1000]
                s3.delete_objects(Bucket='${bucket_name}', Delete={'Objects': batch, 'Quiet': True})
                print(f'    Deleted {len(batch)} objects/versions')
    print('    ✅ Bucket emptied')
except Exception as e:
    print(f'    ⚠️  Error emptying bucket: {e}')
" 2>/dev/null || {
    # Fallback: simple recursive delete
    aws s3 rm "s3://${bucket_name}" --recursive --region "$REGION" 2>/dev/null || true
  }
}

delete_bucket() {
  local bucket_name="$1"

  # Check if bucket exists
  aws s3api head-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null || {
    log_skip "Bucket $bucket_name does not exist"
    return 0
  }

  empty_bucket "$bucket_name"

  log_step "Deleting bucket: $bucket_name"
  aws s3api delete-bucket --bucket "$bucket_name" --region "$REGION" 2>/dev/null && \
    log_ok "Bucket $bucket_name deleted" || \
    log_warn "Could not delete bucket $bucket_name"
}

# KB and OpenAPI buckets — empty and delete
delete_bucket "$KB_BUCKET"
delete_bucket "$OPENAPI_BUCKET"

# CFN templates bucket — just empty the prefix, don't delete (reusable)
log_step "Emptying CFN templates prefix from $BUCKET..."
aws s3 rm "s3://${BUCKET}/${PREFIX}/" --recursive --region "$REGION" 2>/dev/null || true
log_ok "CFN templates prefix cleaned"

echo ""
read -r -p "  Also delete the CFN templates bucket '$BUCKET'? (y/N): " DELETE_CFN_BUCKET
if [[ "$DELETE_CFN_BUCKET" =~ ^[Yy]$ ]]; then
  delete_bucket "$BUCKET"
else
  log_skip "Keeping CFN templates bucket $BUCKET"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 6: Clean up CloudWatch Log Groups
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 6: Clean up CloudWatch Log Groups"

# Build log group search patterns from stack name and environment
LOG_GROUP_PATTERNS=(
  "/aws/lex/ParkAndTollBot"
  "/aws/lex/PaymentCollectionBot"
  "/aws/lambda/${STACK_NAME}"
  "/aws/lambda/ivr-${ENVIRONMENT}"
  "/aws/lambda/ConnectAssistantUpdateSessionData"
  "/aws/apigateway/${STACK_NAME}"
)

for PATTERN in "${LOG_GROUP_PATTERNS[@]}"; do
  log_step "Searching for log groups matching: $PATTERN"

  LOG_GROUPS=$(aws logs describe-log-groups \
    --log-group-name-prefix "$PATTERN" \
    --region "$REGION" \
    --query "logGroups[*].logGroupName" \
    --output text 2>/dev/null) || LOG_GROUPS=""

  if [ -n "$LOG_GROUPS" ] && [ "$LOG_GROUPS" != "None" ]; then
    for LG in $LOG_GROUPS; do
      aws logs delete-log-group \
        --log-group-name "$LG" \
        --region "$REGION" 2>/dev/null && \
        echo "    Deleted: $LG" || \
        echo "    Could not delete: $LG"
    done
  else
    log_skip "No log groups matching $PATTERN"
  fi
done

# ═══════════════════════════════════════════════════════════════
#  PHASE 7: Clean up App Integrations (used by KB)
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 7: Clean up App Integrations"

log_step "Listing App Integrations..."

# Derive search terms from stack name (e.g., "anycompany" from "anycompany-ivr")
SEARCH_PREFIX=$(echo "$STACK_NAME" | cut -d'-' -f1)

APP_INTEGRATIONS=$(aws appintegrations list-data-integrations \
  --region "$REGION" \
  --query "DataIntegrations[?contains(Name, '${SEARCH_PREFIX}')].DataIntegrationArn" \
  --output text 2>/dev/null) || APP_INTEGRATIONS=""

if [ -n "$APP_INTEGRATIONS" ] && [ "$APP_INTEGRATIONS" != "None" ]; then
  for AI_ARN in $APP_INTEGRATIONS; do
    DI_ID=$(echo "$AI_ARN" | awk -F'/' '{print $NF}')
    log_step "Deleting data integration: $DI_ID"
    aws appintegrations delete-data-integration \
      --data-integration-identifier "$DI_ID" \
      --region "$REGION" 2>/dev/null && \
      log_ok "Deleted $DI_ID" || \
      log_warn "Could not delete $DI_ID"
  done
else
  log_skip "No matching App Integrations found"
fi

# ═══════════════════════════════════════════════════════════════
#  PHASE 8: Verification
# ═══════════════════════════════════════════════════════════════

log_header "PHASE 8: Verification"

echo ""
log_step "Checking for remaining CloudFormation stacks..."
REMAINING_STACKS=$(aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED UPDATE_ROLLBACK_COMPLETE \
  --region "$REGION" \
  --query "StackSummaries[?contains(StackName, '${STACK_NAME}')].{Name:StackName,Status:StackStatus}" \
  --output table 2>/dev/null) || REMAINING_STACKS="None"

if [ "$REMAINING_STACKS" = "None" ] || echo "$REMAINING_STACKS" | grep -q "^$"; then
  log_ok "No remaining stacks found"
else
  echo "$REMAINING_STACKS"
  log_warn "Some stacks may still exist"
fi

log_step "Checking for remaining Lex bots..."
if [ -n "$PARK_AND_TOLL_BOT_ID" ]; then
  aws lexv2-models describe-bot --bot-id "$PARK_AND_TOLL_BOT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "ParkAndTollBot still exists!" || log_ok "ParkAndTollBot deleted"
else
  log_ok "ParkAndTollBot was not found initially"
fi

if [ -n "$PAYMENT_BOT_ID" ]; then
  aws lexv2-models describe-bot --bot-id "$PAYMENT_BOT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "PaymentCollectionBot still exists!" || log_ok "PaymentCollectionBot deleted"
else
  log_ok "PaymentCollectionBot was not found initially"
fi

log_step "Checking for remaining Q resources..."
if [ -n "$ASSISTANT_ID" ] && [ "$ASSISTANT_ID" != "None" ]; then
  aws qconnect get-assistant --assistant-id "$ASSISTANT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "Q Assistant still exists!" || log_ok "Q Assistant deleted"
else
  log_ok "Q Assistant was not found initially"
fi

log_step "Checking S3 buckets..."
aws s3api head-bucket --bucket "$KB_BUCKET" --region "$REGION" 2>/dev/null && \
  log_err "KB bucket $KB_BUCKET still exists!" || log_ok "KB bucket deleted"

aws s3api head-bucket --bucket "$OPENAPI_BUCKET" --region "$REGION" 2>/dev/null && \
  log_err "OpenAPI bucket $OPENAPI_BUCKET still exists!" || log_ok "OpenAPI bucket deleted"

# ═══════════════════════════════════════════════════════════════
#  DONE
# ═══════════════════════════════════════════════════════════════

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   🗑️   DESTRUCTION COMPLETE                             ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   Resources that may need manual cleanup:               ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   • Connect Instance (if you want to delete it)         ║${NC}"
echo -e "${GREEN}║     Go to: Connect Console → Instance → Delete          ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   • KMS Keys (schedule deletion in KMS console)         ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   • Service-Linked Role for Lex+Connect                 ║${NC}"
echo -e "${GREEN}║     (auto-managed, usually leave alone)                 ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
if ! [[ "${DELETE_CFN_BUCKET:-}" =~ ^[Yy]$ ]]; then
echo -e "${GREEN}║   • CFN Templates bucket: ${BUCKET}${NC}"
echo -e "${GREEN}║     (prefix emptied but bucket kept — reusable)         ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
fi
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Finished: $(date)"
echo ""