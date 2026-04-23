#!/usr/bin/env bash
###############################################################################
#  destroy-all.sh — Complete teardown of AnyCompany IVR solution
#
#  This script destroys ALL resources in reverse dependency order:
#    1. Lex Bots (manual resources not in CFN)
#    2. Q in Connect AI Agents, Prompts, KB associations
#    3. CloudFormation stacks (reverse order)
#    4. Orphaned resources (S3 buckets, log groups, etc.)
#
#  Usage:
#    chmod +x destroy-all.sh
#    ./destroy-all.sh
#
#  ⚠️  WARNING: This is DESTRUCTIVE and IRREVERSIBLE!
###############################################################################

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
REGION="us-east-1"
ACCOUNT_ID="1234567801"

# Connect & Q
CONNECT_INSTANCE_ID="xxxxx-xxxx-xxxx-xxxx-5b39bf2a2b27"
ASSISTANT_ID="xxxxx-xxxx-xxxx-xxxx-a9795dc3c2c3"

# Lex Bots
PARK_AND_TOLL_BOT_ID="xxxxxxxxx"
PARK_AND_TOLL_ALIAS_ID="xxxxxxxxx"
PAYMENT_BOT_ID="xxxxxxxx"
PAYMENT_BOT_ALIAS_ID="xxxxxxxx"

# Knowledge Base
KB_ID="xxxxxx-xxxxx-xxxxx-xxxxx-9adf6c60b178"
KB_ASSOCIATION_ID="xxxxxx-xxxx-xxxx-xxxxxx-c60c1aa50ad4"

# AI Agents
AI_AGENT_1_ID="xxxxx-xxxx-xxxx-xxxx-b789a53ad33a"   # IVRDemo-Agent
AI_AGENT_2_ID="xxxxxx-xxxxx-xxxx-xxxx-2fadaa73578f"   # ivrdemo-1-orchestration-agent

# S3 Buckets
CF_TEMPLATES_BUCKET="anycompany-cf-templates-xxxxx"
KB_BUCKET="anycompany-kb-bucket-xxxxx"
OPENAPI_BUCKET="anycompany-openapi-xxxxx"

# CloudFormation Stacks (will be deleted in this order — reverse of deployment)
CFN_STACKS=(
    "anycompany-ivr-phase2-qagents"
    "anycompany-ivr-agent-screen-pop"
    "anycompany-ivr-update-session"
    "anycompany-ivr-payment-handoff"
    "anycompany-ivr-api"
    "anycompany-ivr-getCallAttributes"
    "anycompany-ivr-fulfillment-hook"
    "anycompany-ivr-payments-lambdas"
    "anycompany-ivr-lambdas"
    "anycompany-ivr-session-table"
    "anycompany-ivr-dynamodb"
    "anycompany-ivr-client-config"
    "anycompany-ivr"
)

# Lambda functions (for permission cleanup)
FULFILLMENT_LAMBDA="anycompany-ivr-dev-QinConnectDialogHook"
PAYMENT_LAMBDA="ivr-dev-PaymentProcessing"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ─── Helper Functions ────────────────────────────────────────────────────────

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

safe_run() {
    # Run a command, suppress errors but log them
    "$@" 2>/dev/null && return 0 || return 1
}

wait_for_stack_delete() {
    local stack_name="$1"
    local max_wait=300  # 5 minutes
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

# ─── Confirmation ────────────────────────────────────────────────────────────

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   ⚠️   COMPLETE DESTRUCTION OF ANYCOMPANY IVR   ⚠️      ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   This will permanently delete:                          ║${NC}"
echo -e "${RED}║   • Both Lex V2 bots (ParkAndTollBot, PaymentBot)       ║${NC}"
echo -e "${RED}║   • Q in Connect AI Agents, Prompts, KB associations    ║${NC}"
echo -e "${RED}║   • Knowledge Base and all indexed content              ║${NC}"
echo -e "${RED}║   • All ${#CFN_STACKS[@]} CloudFormation stacks                          ║${NC}"
echo -e "${RED}║   • All Lambda functions, DynamoDB tables, API Gateway  ║${NC}"
echo -e "${RED}║   • Connect instance configuration                      ║${NC}"
echo -e "${RED}║   • S3 bucket contents                                  ║${NC}"
echo -e "${RED}║   • CloudWatch log groups                               ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}║   Account:  ${ACCOUNT_ID}                           ║${NC}"
echo -e "${RED}║   Region:   ${REGION}                                    ║${NC}"
echo -e "${RED}║                                                          ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
read -p "  Type 'DESTROY' to confirm: " CONFIRM

if [ "$CONFIRM" != "DESTROY" ]; then
    echo "  Aborted."
    exit 1
fi

echo ""
echo "  Starting destruction in 5 seconds... (Ctrl+C to cancel)"
sleep 5

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 0: Release Phone Numbers
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 0: Release Phone Numbers"

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

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: Disassociate Lex Bots from Connect
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 1: Disassociate Lex Bots from Connect"

for BOT_ID in "$PARK_AND_TOLL_BOT_ID" "$PAYMENT_BOT_ID"; do
    log_step "Disassociating bot $BOT_ID from Connect..."

    # Get the association ID
    ASSOC=$(aws connect list-bots \
        --instance-id "$CONNECT_INSTANCE_ID" \
        --lex-version V2 \
        --region "$REGION" \
        --query "LexBots[?LexBot.LexBotId=='${BOT_ID}'].LexBot.LexBotAliasArn" \
        --output text 2>/dev/null) || ASSOC=""

    if [ -n "$ASSOC" ] && [ "$ASSOC" != "None" ]; then
        aws connect disassociate-bot \
            --instance-id "$CONNECT_INSTANCE_ID" \
            --lex-bot "LexV2Bot={AliasArn=$ASSOC}" \
            --region "$REGION" 2>/dev/null && \
            log_ok "Disassociated bot $BOT_ID" || \
            log_warn "Could not disassociate bot $BOT_ID"
    else
        log_skip "Bot $BOT_ID not associated or already removed"
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: Delete Lex V2 Bots
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 2: Delete Lex V2 Bots"

delete_lex_bot() {
    local BOT_ID="$1"
    local BOT_NAME="$2"
    local ALIAS_ID="$3"

    log_step "Deleting $BOT_NAME ($BOT_ID)..."

    # Check if bot exists
    aws lexv2-models describe-bot --bot-id "$BOT_ID" --region "$REGION" >/dev/null 2>&1 || {
        log_skip "$BOT_NAME does not exist"
        return 0
    }

    # Delete alias (if not TSTALIASID)
    if [ -n "$ALIAS_ID" ] && [ "$ALIAS_ID" != "TSTALIASID" ]; then
        log_step "  Deleting alias $ALIAS_ID..."
        aws lexv2-models delete-bot-alias \
            --bot-id "$BOT_ID" \
            --bot-alias-id "$ALIAS_ID" \
            --skip-resource-in-use-check \
            --region "$REGION" 2>/dev/null && \
            log_ok "  Alias deleted" || \
            log_warn "  Could not delete alias"
        sleep 3
    fi

    # Delete all versions except DRAFT
    log_step "  Deleting bot versions..."
    VERSIONS=$(aws lexv2-models list-bot-versions \
        --bot-id "$BOT_ID" \
        --region "$REGION" \
        --query "botVersionSummaries[?botVersion!='DRAFT'].botVersion" \
        --output text 2>/dev/null) || VERSIONS=""

    for VER in $VERSIONS; do
        aws lexv2-models delete-bot-version \
            --bot-id "$BOT_ID" \
            --bot-version "$VER" \
            --skip-resource-in-use-check \
            --region "$REGION" 2>/dev/null && \
            echo "    Deleted version $VER" || true
    done
    sleep 2

    # Delete the bot
    log_step "  Deleting bot..."
    aws lexv2-models delete-bot \
        --bot-id "$BOT_ID" \
        --skip-resource-in-use-check \
        --region "$REGION" 2>/dev/null && \
        log_ok "$BOT_NAME deleted" || \
        log_err "Could not delete $BOT_NAME"

    # Wait for deletion
    local wait=0
    while [ $wait -lt 60 ]; do
        aws lexv2-models describe-bot --bot-id "$BOT_ID" --region "$REGION" >/dev/null 2>&1 || {
            log_ok "$BOT_NAME fully removed"
            return 0
        }
        sleep 5
        wait=$((wait + 5))
        echo "    Waiting for bot deletion... ${wait}s"
    done
}

delete_lex_bot "$PARK_AND_TOLL_BOT_ID" "ParkAndTollBot" "$PARK_AND_TOLL_ALIAS_ID"
delete_lex_bot "$PAYMENT_BOT_ID" "PaymentCollectionBot" "$PAYMENT_BOT_ALIAS_ID"

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3: Clean up Q in Connect (AI Agents, KB, Associations)
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 3: Clean up Q in Connect Resources"

# This requires boto3 since CLI is too old for these commands
# We'll create a Python helper script

cat > /tmp/cleanup_qconnect.py << 'PYTHON_SCRIPT'
import boto3
import json
import sys
import time

region = 'us-east-1'
assistant_id = 'fd8cc08c-eca3-49e1-b55d-a9795dc3c2c3'
kb_id = '72ac27da-d869-4d6a-bd89-9adf6c60b178'
kb_association_id = '8b347868-51e2-46c8-9015-c60c1aa50ad4'
agent_ids = [
    'be3bce9c-5616-4d10-92aa-b789a53ad33a',  # IVRDemo-Agent
    '71365615-9239-43ca-a08c-2fadaa73578f',  # ivrdemo-1-orchestration-agent
]

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

# Step 1: Remove AI Agent override from assistant
print("\n=== Step 1: Remove AI Agent overrides from assistant ===")
for agent_type in ['ORCHESTRATION', 'SELF_SERVICE']:
    safe_call(
        client.remove_assistant_ai_agent,
        f"Remove {agent_type} agent override",
        assistantId=assistant_id,
        aiAgentType=agent_type
    )

time.sleep(2)

# Step 2: Delete AI Agent versions, then agents
print("\n=== Step 2: Delete AI Agents ===")
for agent_id in agent_ids:
    print(f"\n  Processing agent: {agent_id}")

    # List and delete versions
    try:
        versions = client.list_ai_agent_versions(
            assistantId=assistant_id,
            aiAgentId=agent_id
        )
        for v in versions.get('aiAgentVersionSummaries', []):
            vnum = v.get('versionNumber')
            if vnum:
                safe_call(
                    client.delete_ai_agent_version,
                    f"Delete agent version {vnum}",
                    assistantId=assistant_id,
                    aiAgentId=agent_id,
                    versionNumber=vnum
                )
                time.sleep(1)
    except Exception as e:
        print(f"  ⚠️  Could not list versions for {agent_id}: {e}")

    # Delete the agent itself
    time.sleep(2)
    safe_call(
        client.delete_ai_agent,
        f"Delete agent {agent_id}",
        assistantId=assistant_id,
        aiAgentId=agent_id
    )

# Step 3: Delete AI Prompts
print("\n=== Step 3: Delete AI Prompts ===")
try:
    prompts = client.list_ai_prompts(assistantId=assistant_id)
    for p in prompts.get('aiPromptSummaries', []):
        prompt_id = p.get('aiPromptId')
        prompt_name = p.get('name', 'unknown')

        # Delete versions first
        try:
            pversions = client.list_ai_prompt_versions(
                assistantId=assistant_id,
                aiPromptId=prompt_id
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

# Step 4: Delete KB contents
print("\n=== Step 4: Delete KB contents ===")
try:
    contents = client.list_contents(knowledgeBaseId=kb_id)
    for c in contents.get('contentSummaries', []):
        content_id = c.get('contentId')
        content_name = c.get('title', 'unknown')
        safe_call(
            client.delete_content,
            f"Delete content '{content_name}' ({content_id})",
            knowledgeBaseId=kb_id,
            contentId=content_id
        )
        time.sleep(1)
except Exception as e:
    print(f"  ⚠️  Could not list/delete contents: {e}")

# Step 5: Delete KB association from assistant
print("\n=== Step 5: Delete KB association ===")
safe_call(
    client.delete_assistant_association,
    f"Delete KB association {kb_association_id}",
    assistantId=assistant_id,
    assistantAssociationId=kb_association_id
)
time.sleep(2)

# Step 6: Delete Knowledge Base
print("\n=== Step 6: Delete Knowledge Base ===")
safe_call(
    client.delete_knowledge_base,
    f"Delete KB {kb_id}",
    knowledgeBaseId=kb_id
)

# Step 7: Delete Assistant
print("\n=== Step 7: Delete Assistant ===")
time.sleep(3)
safe_call(
    client.delete_assistant,
    f"Delete assistant {assistant_id}",
    assistantId=assistant_id
)

print("\n=== Q in Connect cleanup complete ===")
PYTHON_SCRIPT

log_step "Running Q in Connect cleanup via Python..."
python /tmp/cleanup_qconnect.py && \
    log_ok "Q in Connect resources cleaned up" || \
    log_warn "Some Q in Connect resources may need manual cleanup"

rm -f /tmp/cleanup_qconnect.py

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 4: Remove Lambda Resource Policies
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 4: Clean up Lambda Resource Policies"

remove_lambda_permissions() {
    local FUNC_NAME="$1"
    log_step "Cleaning permissions for $FUNC_NAME..."

    # Check if function exists
    aws lambda get-function --function-name "$FUNC_NAME" --region "$REGION" >/dev/null 2>&1 || {
        log_skip "$FUNC_NAME does not exist"
        return 0
    }

    # Get all statement IDs from the policy
    POLICY=$(aws lambda get-policy --function-name "$FUNC_NAME" --region "$REGION" 2>/dev/null) || {
        log_skip "No resource policy on $FUNC_NAME"
        return 0
    }

    SIDS=$(echo "$POLICY" | python -c "
import sys, json
try:
    policy = json.loads(json.loads(sys.stdin.read())['Policy'])
    for stmt in policy.get('Statement', []):
        print(stmt['Sid'])
except: pass
" 2>/dev/null) || SIDS=""

    for SID in $SIDS; do
        aws lambda remove-permission \
            --function-name "$FUNC_NAME" \
            --statement-id "$SID" \
            --region "$REGION" 2>/dev/null && \
            echo "    Removed: $SID" || true
    done

    log_ok "$FUNC_NAME permissions cleaned"
}

remove_lambda_permissions "$FULFILLMENT_LAMBDA"
remove_lambda_permissions "$PAYMENT_LAMBDA"

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 5: Delete CloudFormation Stacks
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 5: Delete CloudFormation Stacks (${#CFN_STACKS[@]} stacks)"

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

    # If previous delete failed, try to delete again
    if [ "$STACK_STATUS" = "DELETE_FAILED" ]; then
        log_warn "$STACK in DELETE_FAILED state — retrying with retain..."

        # Get resources that failed to delete
        FAILED_RESOURCES=$(aws cloudformation describe-stack-resources \
            --stack-name "$STACK" \
            --region "$REGION" \
            --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
            --output text 2>/dev/null) || FAILED_RESOURCES=""

        if [ -n "$FAILED_RESOURCES" ]; then
            RETAIN_ARGS=""
            for RES in $FAILED_RESOURCES; do
                RETAIN_ARGS="$RETAIN_ARGS $RES"
            done
            aws cloudformation delete-stack \
                --stack-name "$STACK" \
                --retain-resources $RETAIN_ARGS \
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

    # Wait for deletion
    wait_for_stack_delete "$STACK" || {
        log_err "$STACK failed to delete — may need manual intervention"
    }
done

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 6: Clean up S3 Buckets
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 6: Clean up S3 Buckets"

empty_and_delete_bucket() {
    local BUCKET="$1"
    log_step "Processing bucket: $BUCKET"

    # Check if bucket exists
    aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || {
        log_skip "Bucket $BUCKET does not exist"
        return 0
    }

    # Empty the bucket (including versioned objects)
    log_step "  Emptying $BUCKET..."

    # Delete all object versions
    aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null | \
    python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    objects = data.get('Objects')
    if objects:
        print(json.dumps({'Objects': objects, 'Quiet': True}))
    else:
        sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null | \
    aws s3api delete-objects --bucket "$BUCKET" --delete file:///dev/stdin --region "$REGION" >/dev/null 2>&1 || true

    # Delete all delete markers
    aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --region "$REGION" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null | \
    python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    objects = data.get('Objects')
    if objects:
        print(json.dumps({'Objects': objects, 'Quiet': True}))
    else:
        sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null | \
    aws s3api delete-objects --bucket "$BUCKET" --delete file:///dev/stdin --region "$REGION" >/dev/null 2>&1 || true

    # Also try simple recursive delete
    aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION" 2>/dev/null || true

    # Delete the bucket
    log_step "  Deleting bucket $BUCKET..."
    aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null && \
        log_ok "Bucket $BUCKET deleted" || \
        log_warn "Could not delete bucket $BUCKET (may have remaining objects or be managed by CFN)"
}

empty_and_delete_bucket "$KB_BUCKET"
empty_and_delete_bucket "$OPENAPI_BUCKET"

# Only empty the CF templates bucket — delete is optional
log_step "Emptying CF templates bucket (not deleting)..."
aws s3 rm "s3://${CF_TEMPLATES_BUCKET}/anycompany-ivr/" --recursive --region "$REGION" 2>/dev/null || true
log_ok "CF templates cleaned"

# Uncomment to also delete the CF templates bucket:
# empty_and_delete_bucket "$CF_TEMPLATES_BUCKET"

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 7: Clean up CloudWatch Log Groups
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 7: Clean up CloudWatch Log Groups"

LOG_GROUP_PATTERNS=(
    "/aws/lex/ParkAndTollBot"
    "/aws/lex/PaymentCollectionBot"
    "/aws/lambda/anycompany-ivr"
    "/aws/lambda/ivr-dev"
    "/aws/apigateway/anycompany"
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

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 8: Clean up App Integrations (used by KB)
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 8: Clean up App Integrations"

log_step "Listing App Integrations..."
APP_INTEGRATIONS=$(aws appintegrations list-data-integrations \
    --region "$REGION" \
    --query "DataIntegrations[?contains(Name, 'anycompany') || contains(Name, 'IVRDemo')].DataIntegrationArn" \
    --output text 2>/dev/null) || APP_INTEGRATIONS=""

if [ -n "$APP_INTEGRATIONS" ] && [ "$APP_INTEGRATIONS" != "None" ]; then
    for AI_ARN in $APP_INTEGRATIONS; do
        DI_ID=$(echo "$AI_ARN" | awk -F'/' '{print $NF}')
        log_step "Deleting data integration: $DI_ID"
        aws appintegrations delete-data-integration \
            --data-integration-identifier "$DI_ID" \
            --region "$REGION" 2>/dev/null && \
            log_ok "Deleted $DI_ID" || \
            log_warn "Could not delete $DI_ID (may be managed by Connect)"
    done
else
    log_skip "No matching App Integrations found"
fi

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 9: Verification
# ═══════════════════════════════════════════════════════════════════════════════

log_header "PHASE 9: Verification"

echo ""
log_step "Checking for remaining CloudFormation stacks..."
REMAINING_STACKS=$(aws cloudformation list-stacks \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE DELETE_FAILED \
    --region "$REGION" \
    --query "StackSummaries[?contains(StackName, 'anycompany-ivr')].{Name:StackName,Status:StackStatus}" \
    --output table 2>/dev/null) || REMAINING_STACKS="None"

echo "$REMAINING_STACKS"

log_step "Checking for remaining Lex bots..."
aws lexv2-models describe-bot --bot-id "$PARK_AND_TOLL_BOT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "ParkAndTollBot still exists!" || log_ok "ParkAndTollBot deleted"

aws lexv2-models describe-bot --bot-id "$PAYMENT_BOT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "PaymentCollectionBot still exists!" || log_ok "PaymentCollectionBot deleted"

log_step "Checking for remaining Q resources..."
aws wisdom get-assistant --assistant-id "$ASSISTANT_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "Q Assistant still exists!" || log_ok "Q Assistant deleted"

aws wisdom get-knowledge-base --knowledge-base-id "$KB_ID" --region "$REGION" >/dev/null 2>&1 && \
    log_err "Knowledge Base still exists!" || log_ok "Knowledge Base deleted"

log_step "Checking S3 buckets..."
aws s3api head-bucket --bucket "$KB_BUCKET" --region "$REGION" 2>/dev/null && \
    log_err "KB bucket still exists!" || log_ok "KB bucket deleted"

# ═══════════════════════════════════════════════════════════════════════════════
#  DONE
# ═══════════════════════════════════════════════════════════════════════════════

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
echo -e "${GREEN}║   • KMS Key: 7dfd98fe-614f-43df-80f6-e7d44a71da4f      ║${NC}"
echo -e "${GREEN}║     Schedule deletion in KMS console if desired          ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   • Service-Linked Role for Lex+Connect                 ║${NC}"
echo -e "${GREEN}║     (auto-managed, usually leave alone)                 ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}║   • CF Templates bucket: ${CF_TEMPLATES_BUCKET}  ║${NC}"
echo -e "${GREEN}║     (emptied but not deleted — reusable)                ║${NC}"
echo -e "${GREEN}║                                                          ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""