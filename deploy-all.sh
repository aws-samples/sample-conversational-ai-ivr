#!/usr/bin/env bash
set -euo pipefail

export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export PYTHONLEGACYWINDOWSSTDIO=0

# Cross-platform temp directory
TMP_DIR="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
TMP_DIR="${TMP_DIR%/}"

# ==========================================================
# deploy-all.sh — AnyCompany IVR Complete Deployment
#
# Deploys the full Conversational AI IVR infrastructure:
#   Amazon Connect + Lex V2 + Amazon Q in Connect (Nova Sonic)
#   + Bedrock AgentCore Gateway + API Gateway + Tool Lambdas
#
# REQUIRED env vars (export before running):
#   REGION, STACK_NAME, INSTANCE_ALIAS, BUCKET, PREFIX
#
# Optional env vars (defaults shown):
#   ENVIRONMENT=dev
#   API_STAGE=dev
#   KB_BUCKET=anycompanyivrdemo-client-001-2545
#   KB_PREFIX=CLIENT_001
#   PHASE2_STACK_NAME=${STACK_NAME}-phase2-qagents
#   CFN_DIR=cfn
#   AGENTCORE_GW_NAME=c001-ivr-mcp-gw
#   AGENTCORE_TARGET_NAME=anycompanyDemoIVRApi
#
# Usage:
#   source env.sh
#   ./deploy-all.sh
#
# Deployment Order:
#   Phase 0:  Backend infra (DynamoDB + Lambdas + API Gateway)
#   Phase 1:  Connect + AgentCore + Q in Connect (root nested stack)
#   Phase 1b: Connect-dependent stacks (payment handoff, session update)
#   ── MANUAL STEPS ──
#   Phase 2:  AI Agent configuration (QAgents)
# ==========================================================

# ============================================================
# Required Variables — script exits if any are missing
# ============================================================
REGION="${REGION:?ERROR: export REGION before running (e.g., us-east-1)}"
STACK_NAME="${STACK_NAME:?ERROR: export STACK_NAME before running (e.g., anycompany-ivr)}"
INSTANCE_ALIAS="${INSTANCE_ALIAS:?ERROR: export INSTANCE_ALIAS before running (e.g., anycompany-demo)}"
BUCKET="${BUCKET:?ERROR: export BUCKET before running (S3 bucket for templates, must exist)}"
PREFIX="${PREFIX:?ERROR: export PREFIX before running (S3 prefix, e.g., anycompany-ivr/templates)}"
OPENAPI_BUCKET="${OPENAPI_BUCKET:?ERROR: export OPENAPI_BUCKET before running (S3 OPENAPI_BUCKET for OpenAPI Schema file, must exist)}"
KB_BUCKET="${KB_BUCKET:?ERROR: export KB_BUCKET before running (S3 KB_BUCKET for KnowledgeBase file, must exist)}"

# ============================================================
# Optional Variables — defaults used if not set
# ============================================================
ENVIRONMENT="${ENVIRONMENT:-dev}"
API_STAGE="${API_STAGE:-dev}"
KB_BUCKET="${KB_BUCKET:-anycompanyivrdemo-client-001-2545}"
KB_PREFIX="${KB_PREFIX:-CLIENT_001}"
PHASE2_STACK_NAME="${PHASE2_STACK_NAME:-${STACK_NAME}-phase2-qagents}"
CFN_DIR="${CFN_DIR:-cfn}"
AGENTCORE_GW_NAME="${AGENTCORE_GW_NAME:-c001-ivr-mcp-gw}"
AGENTCORE_TARGET_NAME="${AGENTCORE_TARGET_NAME:-anycompanyDemoIVRApi}"

# ============================================================
# Helper Functions
# ============================================================

# Deploy a CloudFormation stack with standard options
deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Deploying: $stack_name"
  echo "  Template:  $template"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [ ! -f "$template" ]; then
    echo "ERROR: Template file not found: $template"
    exit 1
  fi

  aws cloudformation deploy \
    --region "$REGION" \
    --stack-name "$stack_name" \
    --template-file "$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    "$@"

  echo "  ✅ $stack_name: DEPLOYED"
}

# Get a stack output value by key
get_output() {
  local stack="$1"
  local key="$2"
  local value

  value=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text 2>/dev/null)

  if [ -z "$value" ] || [ "$value" = "None" ]; then
    echo "ERROR: Could not retrieve output '${key}' from stack '${stack}'" >&2
    exit 1
  fi

  echo "$value"
}

# Get the physical resource ID of a nested stack
get_nested_stack_id() {
  local logical_id="$1"
  local value

  value=$(aws cloudformation describe-stack-resources \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --logical-resource-id "$logical_id" \
    --query "StackResources[0].PhysicalResourceId" \
    --output text 2>/dev/null)

  if [ -z "$value" ] || [ "$value" = "None" ]; then
    echo "ERROR: Could not find nested stack '${logical_id}' in '${STACK_NAME}'" >&2
    exit 1
  fi

  echo "$value"
}

# Wait for a stack to reach a stable state
wait_for_stack() {
  local stack_name="$1"
  echo "  Waiting for $stack_name to stabilize..."
  aws cloudformation wait stack-create-complete \
    --region "$REGION" \
    --stack-name "$stack_name" 2>/dev/null || \
  aws cloudformation wait stack-update-complete \
    --region "$REGION" \
    --stack-name "$stack_name" 2>/dev/null || true
}

# ============================================================
# Pre-flight Checks
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   AnyCompany IVR — Full Deployment              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "  Account:          $ACCOUNT_ID"
echo "  Region:           $REGION"
echo "  Environment:      $ENVIRONMENT"
echo "  Stack Name:       $STACK_NAME"
echo "  Instance Alias:   $INSTANCE_ALIAS"
echo "  S3 Bucket:        $BUCKET"
echo "  S3 Prefix:        $PREFIX"
echo "  CFN Directory:    $CFN_DIR"
echo "  API Stage:        $API_STAGE"
echo "  AgentCore GW:     $AGENTCORE_GW_NAME"
echo "  AgentCore Target: $AGENTCORE_TARGET_NAME"
echo "  KB Bucket:        $KB_BUCKET"
echo "  KB Prefix:        $KB_PREFIX"
echo "  OpenAPI Schema Bucket:        $OPENAPI_BUCKET"
echo "  Phase 2 Stack:    $PHASE2_STACK_NAME"
echo ""


# ============================================================
# Orphan Check — warn about leftover resources
# ============================================================
echo ""
echo "  Checking for orphaned resources from previous deployments..."

ORPHAN_LAMBDA=$(aws lambda list-functions --region "$REGION" \
  --query "Functions[?contains(FunctionName,'bootstrap')].FunctionName" --output text 2>/dev/null || true)
if [ -n "$ORPHAN_LAMBDA" ] && [ "$ORPHAN_LAMBDA" != "None" ]; then
  echo "  ⚠️  Orphaned Lambda found: $ORPHAN_LAMBDA"
  echo "  Delete it: aws lambda delete-function --function-name $ORPHAN_LAMBDA --region $REGION"
fi



if [ -n "$ORPHAN_LAMBDA" ] && [ "$ORPHAN_LAMBDA" != "None" ]; then
  echo ""
  read -r -p "  Delete orphaned Lambda before continuing? (y/N): " CLEANUP
  if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
    aws lambda delete-function --function-name "$ORPHAN_LAMBDA" --region "$REGION" && echo "  ✅ Deleted $ORPHAN_LAMBDA"
  fi
fi

# Verify S3 bucket exists
if ! aws s3 ls "s3://$BUCKET" --region "$REGION" > /dev/null 2>&1; then
  echo "ERROR: S3 bucket '$BUCKET' does not exist or is not accessible."
  echo "Create it first: aws s3 mb s3://$BUCKET --region $REGION"
  exit 1
fi
echo "  ✅ S3 bucket verified: $BUCKET"

# Verify CFN directory exists
if [ ! -d "$CFN_DIR" ]; then
  echo "ERROR: CloudFormation template directory '$CFN_DIR' not found."
  echo "Set CFN_DIR to the correct path."
  exit 1
fi
echo "  ✅ Template directory verified: $CFN_DIR"
echo ""

read -r -p "  Press ENTER to begin deployment (Ctrl+C to cancel)... " _

# ============================================================
# PHASE 0: Backend Infrastructure
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PHASE 0: Backend Infrastructure               ║"
echo "║   DynamoDB tables, Lambdas, API Gateway          ║"
echo "╚══════════════════════════════════════════════════╝"

# ----------------------------------------------------------
# 0a. Client Config DynamoDB Table
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-client-config" \
  "$CFN_DIR/standalone/01a-client-config-table.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT"

# ----------------------------------------------------------
# 0b. Core DynamoDB Tables (Customers, Violations, Disputes)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-dynamodb" \
  "$CFN_DIR/standalone/01b-dynamodb-tables.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT"

# ----------------------------------------------------------
# 0c. Session Table + KMS Key (for payment session context)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-session-table" \
  "$CFN_DIR/standalone/01c-session-table.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT"

# ----------------------------------------------------------
# 0d. Tool Lambdas (7 non-payment: lookups, balance, disputes)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-lambdas" \
  "$CFN_DIR/standalone/02a-tool-lambdas.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    DynamoDBStackName="anycompany-ivr-dynamodb"

# ----------------------------------------------------------
# 0e. Payment Tool Lambdas (buildPaymentCart, initiatePayment)
#     Depends on: session-table (01c), dynamodb (01b)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-payments-lambdas" \
  "$CFN_DIR/standalone/02d-payments-lambdas.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    DynamoDBStackName="anycompany-ivr-dynamodb" \
    SessionTableStackName="anycompany-ivr-session-table"

# ----------------------------------------------------------
# 0f. Fulfillment Code Hook Lambda (QinConnectDialogHook)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-fulfillment-hook" \
  "$CFN_DIR/standalone/02f-fulfillment-hook.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT"

# ----------------------------------------------------------
# 0g. getCallAttributes Lambda
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-getCallAttributes" \
  "$CFN_DIR/standalone/02b-getCallAttributes.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    ClientConfigTableName="anycompany-ivr-client-config-${ENVIRONMENT}"

# ----------------------------------------------------------
# 0h. API Gateway (ALL 9 endpoints)
#     Depends on: tool-lambdas (02a), payments-lambdas (02d)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-api" \
  "$CFN_DIR/standalone/03-api-gateway.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    LambdaStackName="anycompany-ivr-lambdas" \
    PaymentsLambdaStackName="anycompany-ivr-payments-lambdas"

# ----------------------------------------------------------
# Retrieve API Gateway outputs
# ----------------------------------------------------------
REST_API_ID=$(get_output "anycompany-ivr-api" "ApiId")
API_KEY_ID=$(get_output "anycompany-ivr-api" "ApiKeyId")
API_ENDPOINT="https://${REST_API_ID}.execute-api.${REGION}.amazonaws.com/${API_STAGE}"

echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │ API Gateway Deployed                         │"
echo "  │  API ID:     $REST_API_ID"
echo "  │  API Key ID: $API_KEY_ID"
echo "  │  Endpoint:   $API_ENDPOINT"
echo "  └─────────────────────────────────────────────┘"

# ----------------------------------------------------------
# Update OpenAPI spec with real API Gateway URL
# ----------------------------------------------------------
echo ""
echo "  Updating openapi.yaml with real API Gateway URL..."
echo "    Before: $(grep 'url:' "$CFN_DIR/openapi.yaml" | head -1 | xargs)"

sed "s|https://.*execute-api\..*amazonaws\.com/[^ ]*|${API_ENDPOINT}|g" \
    "$CFN_DIR/openapi.yaml" > "${TMP_DIR}/openapi-updated.yaml"

echo "    After:  $(grep 'url:' "${TMP_DIR}/openapi-updated.yaml" | head -1 | xargs)"

# Verify the substitution worked
if ! grep -q "$REST_API_ID" "${TMP_DIR}/openapi-updated.yaml"; then
  echo "  ERROR: OpenAPI spec URL substitution failed!"
  echo "  Check the server URL format in $CFN_DIR/openapi.yaml"
  exit 1
fi
echo "  ✅ OpenAPI spec updated successfully"

echo ""
echo "  ✅ PHASE 0 COMPLETE"

# ============================================================
# PHASE 1: Connect + AgentCore + Q in Connect
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PHASE 1: Connect + AgentCore + Q in Connect   ║"
echo "║   Root nested stack deployment                   ║"
echo "╚══════════════════════════════════════════════════╝"

# ----------------------------------------------------------
# Upload nested templates and artifacts to S3
# ----------------------------------------------------------
echo ""
echo "  Uploading nested templates to S3..."

NESTED_TEMPLATES=(
  connect-instance.yaml
  connect-config.yaml
  agentcore-gateway.yaml
  agentcore-target.yaml
  bootstrap.yaml
  mcp-application.yaml
)

for f in "${NESTED_TEMPLATES[@]}"; do
  if [ -f "$CFN_DIR/nested/$f" ]; then
    aws s3 cp "$CFN_DIR/nested/$f" "s3://$BUCKET/$PREFIX/$f" --region "$REGION" --quiet
    echo "    ✅ nested/$f → s3://$BUCKET/$PREFIX/$f"
  elif [ -f "$CFN_DIR/$f" ]; then
    aws s3 cp "$CFN_DIR/$f" "s3://$BUCKET/$PREFIX/$f" --region "$REGION" --quiet
    echo "    ✅ $f → s3://$BUCKET/$PREFIX/$f"
  else
    echo "    ❌ WARNING: Template not found: $f (checked nested/ and root)"
  fi
done

# Upload the UPDATED openapi.yaml (with real API Gateway URL)
aws s3 cp "${TMP_DIR}/openapi-updated.yaml" \
    "s3://$OPENAPI_BUCKET/openapi.yaml" --region "$REGION" --quiet
echo "    ✅ openapi.yaml (updated URL) → s3://$OPENAPI_BUCKET/openapi.yaml"

# Upload bootstrap Lambda code if it exists
if [ -f "$CFN_DIR/bootstrap-lambda.zip" ]; then
  aws s3 cp "$CFN_DIR/bootstrap-lambda.zip" \
      "s3://$BUCKET/$PREFIX/bootstrap-lambda.zip" --region "$REGION" --quiet
  echo "    ✅ bootstrap-lambda.zip → s3://$BUCKET/$PREFIX/bootstrap-lambda.zip"
elif [ -f "$CFN_DIR/nested/bootstrap-lambda.zip" ]; then
  aws s3 cp "$CFN_DIR/nested/bootstrap-lambda.zip" \
      "s3://$BUCKET/$PREFIX/bootstrap-lambda.zip" --region "$REGION" --quiet
  echo "    ✅ nested/bootstrap-lambda.zip → s3://$BUCKET/$PREFIX/bootstrap-lambda.zip"
else
  echo "    ⚠️  WARNING: bootstrap-lambda.zip not found — bootstrap custom resource may fail"
fi

echo "  Upload complete."

# ----------------------------------------------------------
# Build S3 template URLs
# ----------------------------------------------------------
S3_BASE="https://${BUCKET}.s3.${REGION}.amazonaws.com/${PREFIX}"

# ----------------------------------------------------------
# Deploy root nested stack
# ----------------------------------------------------------
deploy_stack "$STACK_NAME" \
  "$CFN_DIR/standalone/root.yaml" \
  --parameter-overrides \
    DeployQAgents=false \
    InstanceAlias="$INSTANCE_ALIAS" \
    AgentCoreGatewayName="$AGENTCORE_GW_NAME" \
    AgentCoreTargetName="$AGENTCORE_TARGET_NAME" \
    OpenApiSchemaBucket="$OPENAPI_BUCKET" \
    OpenApiSchemaKey="openapi.yaml" \
    ApiGatewayRestApiId="$REST_API_ID" \
    ApiGatewayStageName="$API_STAGE" \
    ApiGatewayApiKeyId="$API_KEY_ID" \
    KnowledgeBaseS3Bucket="$KB_BUCKET" \
    KnowledgeBaseS3Prefix="$KB_PREFIX" \
    ConnectInstanceTemplateUrl="${S3_BASE}/connect-instance.yaml" \
    ConnectConfigTemplateUrl="${S3_BASE}/connect-config.yaml" \
    AgentCoreGatewayTemplateUrl="${S3_BASE}/agentcore-gateway.yaml" \
    AgentCoreTargetTemplateUrl="${S3_BASE}/agentcore-target.yaml" \
    BootstrapTemplateUrl="${S3_BASE}/bootstrap.yaml" \
    BootstrapCodeS3Bucket="$BUCKET" \
    BootstrapCodeS3Key="$PREFIX/bootstrap-lambda.zip" \
    McpApplicationName="mcp_tools" \
    McpApplicationTemplateUrl="${S3_BASE}/mcp-application.yaml"

# ----------------------------------------------------------
# Retrieve Phase 1 outputs
# ----------------------------------------------------------
echo ""
echo "  Retrieving Phase 1 outputs..."

CONNECT_STACK_ID=$(get_nested_stack_id "ConnectInstanceStack")
CONNECT_INSTANCE_ARN=$(get_output "$CONNECT_STACK_ID" "ConnectInstanceArn")
CONNECT_INSTANCE_ID=$(get_output "$CONNECT_STACK_ID" "ConnectInstanceId")
# Get from nested stack to avoid root stack's double-ARN bug


CONFIG_STACK_ID=$(get_nested_stack_id "ConnectConfigStack")
ASSISTANT_ID=$(get_output "$CONFIG_STACK_ID" "QInConnectAssistantId")
ASSISTANT_ARN=$(get_output "$CONFIG_STACK_ID" "QInConnectAssistantArn")
PROMPT_ID=$(get_output "$CONFIG_STACK_ID" "OrchestrationPromptId")

GATEWAY_STACK_ID=$(get_nested_stack_id "AgentCoreGatewayStack")
TARGET_STACK_ID=$(get_nested_stack_id "AgentCoreTargetStack")
GATEWAY_ID=$(get_output "$GATEWAY_STACK_ID" "GatewayId")
TARGET_NAME=$(get_output "$TARGET_STACK_ID" "AgentCoreTargetName")

# Compute ToolNamePrefix: replace hyphens with underscores
TOOL_NAME_PREFIX="${TARGET_NAME//-/_}"

echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ Phase 1 Outputs                                      │"
echo "  │  Connect Instance ARN:    $CONNECT_INSTANCE_ARN"
echo "  │  Connect Instance ID:     $CONNECT_INSTANCE_ID"
echo "  │  Q Assistant ID:          $ASSISTANT_ID"
echo "  │  Q Assistant ARN:         $ASSISTANT_ARN"
echo "  │  Orchestration Prompt ID: $PROMPT_ID"
echo "  │  AgentCore Gateway ID:    $GATEWAY_ID"
echo "  │  AgentCore Target Name:   $TARGET_NAME"
echo "  │  Tool Name Prefix:        $TOOL_NAME_PREFIX"
echo "  └─────────────────────────────────────────────────────┘"

echo ""
echo "  ✅ PHASE 1 COMPLETE"

# ============================================================
# PHASE 1b: Connect-Dependent Stacks
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PHASE 1b: Connect-Dependent Stacks            ║"
echo "║   Payment handoff, session update, screen pop    ║"
echo "╚══════════════════════════════════════════════════╝"

# ----------------------------------------------------------
# Payment Handoff (4 Lambdas: SaveRestore, Seed, Processing, UpdateBalance)
# Depends on: Connect (Phase 1), session-table (01c), dynamodb (01b)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-payment-handoff" \
  "$CFN_DIR/standalone/02e-payment-handoff-resources.yaml" \
  --parameter-overrides \
    Environment="$ENVIRONMENT" \
    ConnectInstanceArn="$CONNECT_INSTANCE_ARN" \
    DynamoDBStackName="anycompany-ivr-dynamodb" \
    SessionTableStackName="anycompany-ivr-session-table"

# ----------------------------------------------------------
# UpdateSessionData Lambda
# Depends on: Q Assistant ARN (Phase 1), Connect ARN (Phase 1)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-update-session" \
  "$CFN_DIR/standalone/02c-ConnectAssistantUpdateSessionData.yaml" \
  --parameter-overrides \
    AiAssistantARN="$ASSISTANT_ARN" \
    ConnectInstanceARN="$CONNECT_INSTANCE_ARN"

# ----------------------------------------------------------
# Agent Screen Pop (View + Contact Flow for escalation)
# Depends on: Connect ARN (Phase 1)
# ----------------------------------------------------------
deploy_stack "anycompany-ivr-agent-screen-pop" \
  "$CFN_DIR/standalone/agent-screen-pop-view.yaml" \
  --parameter-overrides \
    ConnectInstanceArn="$CONNECT_INSTANCE_ARN"

echo ""
echo "  ✅ PHASE 1b COMPLETE"

# ============================================================
# MANUAL STEPS — Pause for user action
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║   ⏸️  MANUAL STEPS REQUIRED BEFORE PHASE 2              ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  1. Follow                                               ║"
echo "║ docs/docs/Manual-post-phase1-and-2-deployment-steps.md   ║"
echo "║     for all the manual steps post Phase-1                ║"
echo "║                                                          ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Key resource references for manual steps:"
echo "    Connect Instance ARN:     $CONNECT_INSTANCE_ARN"
echo "    Connect Instance ID:      $CONNECT_INSTANCE_ID"
echo "    Q Assistant ID:           $ASSISTANT_ID"
echo "    DialogHook Lambda:        ivr-${ENVIRONMENT}-QinConnectDialogHook"
echo "    PaymentProcessing Lambda: ivr-${ENVIRONMENT}-PaymentProcessing"
echo ""

read -r -p "  Press ENTER after completing all manual steps to deploy Phase 2... " _

# ============================================================
# PHASE 2: AI Agent Configuration (QAgents)
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   PHASE 2: AI Agent Configuration               ║"
echo "║   13 tool configs (9 MCP + 2 RTC + 2 payment)   ║"
echo "╚══════════════════════════════════════════════════╝"

echo ""
echo "  Deploying with:"
echo "    ConnectInstanceArn:    $CONNECT_INSTANCE_ARN"
echo "    QInConnectAssistantId: $ASSISTANT_ID"
echo "    OrchestrationPromptId: $PROMPT_ID"
echo "    AgentCoreGatewayId:    $GATEWAY_ID"
echo "    AgentCoreTargetName:   $TARGET_NAME"
echo "    ToolNamePrefix:        $TOOL_NAME_PREFIX"

deploy_stack "$PHASE2_STACK_NAME" \
  "$CFN_DIR/standalone/qagents-v49.yaml" \
  --parameter-overrides \
    InstanceAlias="$INSTANCE_ALIAS" \
    ConnectInstanceArn="$CONNECT_INSTANCE_ARN" \
    QInConnectAssistantIdOrArn="$ASSISTANT_ID" \
    OrchestrationPromptId="$PROMPT_ID" \
    Locale="en_US" \
    AgentCoreGatewayId="$GATEWAY_ID" \
    AgentCoreTargetName="$TARGET_NAME" \
    ToolNamePrefix="$TOOL_NAME_PREFIX"

echo ""
echo "  ✅ PHASE 2 COMPLETE"

# ============================================================
# DEPLOYMENT COMPLETE
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║   ✅  DEPLOYMENT COMPLETE                               ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  Post-deployment steps:                                  ║"
echo "║    1. Create AI Agent Version in Q console               ║"
echo "║    2. Activate the agent version                         ║"
echo "║    3. Test end-to-end (call the phone number)            ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ Deployed Stacks                                      │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │ Phase 0: Backend Infrastructure                      │"
echo "  │   anycompany-ivr-client-config                       │"
echo "  │   anycompany-ivr-dynamodb                            │"
echo "  │   anycompany-ivr-session-table                       │"
echo "  │   anycompany-ivr-lambdas                             │"
echo "  │   anycompany-ivr-payments-lambdas                    │"
echo "  │   anycompany-ivr-fulfillment-hook                    │"
echo "  │   anycompany-ivr-getCallAttributes                   │"
echo "  │   anycompany-ivr-api                                 │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │ Phase 1: Connect + AgentCore + Q                     │"
echo "  │   $STACK_NAME (root + nested stacks)"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │ Phase 1b: Connect-Dependent                          │"
echo "  │   anycompany-ivr-payment-handoff                     │"
echo "  │   anycompany-ivr-update-session                      │"
echo "  │   anycompany-ivr-agent-screen-pop                    │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │ Phase 2: AI Agent                                    │"
echo "  │   $PHASE2_STACK_NAME"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │ Key Resources                                        │"
echo "  ├─────────────────────────────────────────────────────┤"
echo "  │ Connect Instance:  $CONNECT_INSTANCE_ARN"
echo "  │ Q Assistant:       $ASSISTANT_ID"
echo "  │ API Gateway:       $API_ENDPOINT"
echo "  │ AgentCore Gateway: $GATEWAY_ID"
echo "  │ Target Name:       $TARGET_NAME"
echo "  │ Tool Prefix:       $TOOL_NAME_PREFIX"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  Total stacks deployed: 12"
echo "  Deployment finished at: $(date)"
echo ""