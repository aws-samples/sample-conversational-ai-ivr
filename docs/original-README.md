

```markdown
# AnyCompany Parking & Tolling Services — Conversational AI IVR

## Overview

A production-grade **Conversational AI IVR** system built on AWS that enables callers to manage parking violations, toll balances, disputes, and payments through natural voice conversation with an AI agent named **"Alex"**.

The system uses **Amazon Nova Sonic** (via Amazon Q in Connect) for real-time speech-to-speech AI conversation, integrated with backend services through **Bedrock AgentCore Gateway** using the **MCP (Model Context Protocol)**.

---

## Architecture

```
Caller (PSTN)
  │
  ▼
Amazon Connect (Contact Flows)
  │
  ├── getCallAttributes Lambda ──► client-config DynamoDB
  │
  ▼
ParkAndTollBot (Amazon Lex V2)
  │
  ├── AmazonQinConnect Intent
  │     │
  │     ▼
  │   Amazon Q in Connect (Nova Sonic AI — "Alex")
  │     │
  │     ├── Knowledge Base (S3 → Policy docs, FAQs)
  │     ├── AI Prompt (System instructions)
  │     ├── AI Agent (13 tool configurations)
  │     │
  │     ▼
  │   Bedrock AgentCore Gateway (MCP Protocol)
  │     │
  │     ▼
  │   AgentCore Target (OpenAPI Schema + API Key Auth)
  │     │
  │     ▼
  │   Amazon API Gateway (REST, 9 endpoints)
  │     │
  │     ├── /account/lookup-by-plate      ──► lookupByPlate Lambda      ──► customers DynamoDB
  │     ├── /account/lookup-by-citation   ──► lookupByCitation Lambda   ──► customers DynamoDB
  │     ├── /account/lookup-by-account    ──► lookupByAccount Lambda    ──► customers DynamoDB
  │     ├── /balance/get-balance          ──► getBalance Lambda         ──► violations DynamoDB
  │     ├── /balance/get-violation-details──► getViolationDetails Lambda──► violations DynamoDB
  │     ├── /disputes/submit              ──► submitDispute Lambda      ──► disputes DynamoDB
  │     ├── /disputes/status              ──► checkDisputeStatus Lambda ──► disputes DynamoDB
  │     ├── /payments/build-cart          ──► buildPaymentCart Lambda   ──► IVRSessionContext DynamoDB
  │     └── /payments/initiate            ──► initiatePayment Lambda    ──► IVRSessionContext DynamoDB
  │
  ├── QinConnectDialogHook Lambda (Fulfillment Code Hook)
  │     Sets routing attributes: Tool, escalationReason
  │
  ├── [Payment Flow] ──► PaymentCollectionBot (Lex V2, PCI-Compliant)
  │     SaveAndRestoreSession ──► SeedPaymentSession ──► PaymentProcessing ──► UpdateViolationBalance
  │
  └── [Escalation] ──► Agent Screen Pop ──► Live Agent
```

### Signal Chain (Conversation End → Connect Routing)

```
Tool Lambda (returns result)
  → Nova Sonic AI (CLOSED session)
    → Lex V2 (Fulfilled)
      → QinConnectDialogHook (sets Tool + escalationReason attributes)
        → Connect Flow (routes: payment handoff / escalation / end call)
```

### Payment Flow (PCI-Compliant)

```
1. AI calls buildPaymentCart → initiatePayment → conversation ends
2. Connect routes to PCI bot flow
3. SaveAndRestoreSession (saves AI session context)
4. SeedPaymentSession (prepares PCI bot session)
5. PaymentCollectionBot collects card details
6. PaymentProcessing (processes payment)
7. UpdateViolationBalance (updates violation records)
8. SaveAndRestoreSession (restores AI session)
9. Conversation resumes with Alex
```

---

## AWS Services Used

| Service | Purpose |
|---------|---------|
| **Amazon Connect** | Contact center platform, call orchestration, contact flows |
| **Amazon Lex V2** | Speech recognition, intent routing (ParkAndTollBot + PaymentCollectionBot) |
| **Amazon Q in Connect** | AI agent orchestration with Nova Sonic model |
| **Amazon Nova Sonic** | Real-time speech-to-speech conversational AI |
| **Amazon Bedrock AgentCore** | MCP Gateway connecting AI to backend tools |
| **Amazon API Gateway** | REST API exposing tool Lambda endpoints with API key auth |
| **AWS Lambda** | Backend business logic (16 functions total) |
| **Amazon DynamoDB** | Data storage (5 tables) |
| **Amazon S3** | Knowledge base documents, OpenAPI spec, CloudFormation templates |
| **AWS KMS** | Encryption for payment session data |
| **AWS Systems Manager** | Parameter Store for configuration |
| **AWS CloudFormation** | Infrastructure as Code (12 stacks + nested stacks) |

---

## Project Structure

```
project-root/
│
├── deploy-all.sh                              # Main deployment script
├── env.sh                                     # Environment variables (create from env.sh.example)
├── README.md                                  # This file
│
├── cfn/                                       # CloudFormation templates
│   │
│   │── 01a-client-config-table.yaml           # Client config DynamoDB table
│   │── 01b-dynamodb-tables.yaml               # Customers, Violations, Disputes tables
│   │── 02a-tool-lambdas.yaml                  # 7 tool Lambdas (account, balance, disputes)
│   │── 02b-getCallAttributes.yaml             # getCallAttributes Lambda
│   │── 02c-ConnectAssistantUpdateSessionData.yaml  # UpdateSessionData Lambda
│   │── 02d-payments-lambdas.yaml              # 2 payment tool Lambdas (buildCart, initiate)
│   │── 02e-payment-handoff-resources.yaml     # Payment infra (KMS, DDB, 4 Lambdas)
│   │── 02f-fulfillment-hook.yaml              # QinConnectDialogHook Lambda
│   │── 03-api-gateway.yaml                    # API Gateway (9 endpoints)
│   │── root.yaml                              # Root nested stack (Connect + AgentCore + Q)
│   │── qagents-v49.yaml                       # AI Agent configuration (13 tools)
│   │── agent-screen-pop-view.yaml             # Agent escalation screen pop
│   │── openapi.yaml                           # OpenAPI 3.0.1 spec (9 operations)
│   │── bootstrap-lambda.zip                   # Bootstrap custom resource code
│   │
│   └── nested/                                # Nested stack templates (uploaded to S3)
│       ├── connect-instance.yaml              # Connect instance
│       ├── connect-config.yaml                # Q Assistant, KB, AI Prompt
│       ├── agentcore-gateway.yaml             # AgentCore MCP Gateway
│       ├── agentcore-target.yaml              # Gateway Target + OpenAPI schema
│       ├── bootstrap.yaml                     # Custom resource (API key provisioning)
│       └── mcp-application.yaml               # AppIntegrations MCP Server application
│
├── lambda/                                    # Lambda function source code
│   ├── tool-lambdas/
│   │   ├── lookupByPlate/
│   │   ├── lookupByCitation/
│   │   ├── lookupByAccount/
│   │   ├── getBalance/
│   │   ├── getViolationDetails/
│   │   ├── submitDispute/
│   │   └── checkDisputeStatus/
│   ├── payment-tool-lambdas/
│   │   ├── buildPaymentCart/
│   │   └── initiatePayment/
│   ├── flow-helper-lambdas/
│   │   ├── getCallAttributes/
│   │   ├── UpdateSessionData/
│   │   ├── SaveAndRestoreSession/
│   │   ├── SeedPaymentSession/
│   │   ├── PaymentProcessing/
│   │   ├── UpdateViolationBalance/
│   │   └── QinConnectDialogHook/
│   └── bootstrap/
│       └── index.py                           # Custom resource for AgentCore credential setup
│
├── connect-flows/                             # Amazon Connect contact flow exports
│   ├── inbound-flow.json
│   ├── payment-flow.json
│   └── agent-transfer-flow.json
│
├── knowledge-base/                            # Q in Connect knowledge base documents
│   ├── parking-policies.md
│   ├── toll-policies.md
│   ├── payment-faqs.md
│   └── dispute-process.md
│
└── test-data/                                 # DynamoDB seed data
    ├── seed-client-config.json
    ├── seed-customers.json
    ├── seed-violations.json
    └── seed-disputes.json
```

---

## Prerequisites

### AWS Account Requirements

- AWS Account with appropriate permissions (Admin or equivalent)
- Region: **us-east-1** (required for Amazon Q in Connect + Nova Sonic)
- Amazon Connect service quota for new instances
- Amazon Bedrock model access enabled for Nova Sonic

### Local Requirements

- **AWS CLI v2** configured with credentials
- **bash** (Linux/macOS or WSL on Windows)
- **jq** (optional, for output parsing)

### Pre-existing Resources

- **S3 bucket** for CloudFormation template artifacts (the script uploads nested templates here)
- **S3 bucket** for Knowledge Base documents (can be the same bucket with different prefix)

---

## Configuration

### Environment Variables

Create an `env.sh` file from the example:

```bash
# env.sh — Environment configuration

# ============================================
# REQUIRED — Script will fail without these
# ============================================
export REGION="us-east-1"
export STACK_NAME="anycompany-ivr"
export INSTANCE_ALIAS="anycompany-demo"
export BUCKET="my-cfn-artifacts-bucket"          # Must exist already
export PREFIX="anycompany-ivr/templates"         # S3 prefix for uploaded templates

# ============================================
# OPTIONAL — Defaults shown
# ============================================
export ENVIRONMENT="dev"                         # Environment suffix for resource names
export API_STAGE="dev"                           # API Gateway stage name
export KB_BUCKET="anycompanyivrdemo-client-001-2545"  # Knowledge base S3 bucket
export KB_PREFIX="CLIENT_001"                    # Knowledge base S3 prefix
export CFN_DIR="cfn"                             # Local directory containing templates
export AGENTCORE_GW_NAME="c001-ivr-mcp-gw"      # AgentCore Gateway name
export AGENTCORE_TARGET_NAME="anycompanyDemoIVRApi"  # AgentCore Target name
export PHASE2_STACK_NAME="${STACK_NAME}-phase2-qagents"  # Phase 2 stack name
```

### Variable Reference

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `REGION` | **Yes** | — | AWS region (must be `us-east-1` for Nova Sonic) |
| `STACK_NAME` | **Yes** | — | Root CloudFormation stack name |
| `INSTANCE_ALIAS` | **Yes** | — | Amazon Connect instance alias |
| `BUCKET` | **Yes** | — | S3 bucket for template artifacts (must exist) |
| `PREFIX` | **Yes** | — | S3 key prefix for uploaded templates |
| `ENVIRONMENT` | No | `dev` | Environment name suffix |
| `API_STAGE` | No | `dev` | API Gateway deployment stage |
| `KB_BUCKET` | No | `anycompanyivrdemo-client-001-2545` | Knowledge base S3 bucket |
| `KB_PREFIX` | No | `CLIENT_001` | Knowledge base S3 prefix |
| `CFN_DIR` | No | `cfn` | Local template directory |
| `AGENTCORE_GW_NAME` | No | `c001-ivr-mcp-gw` | AgentCore Gateway name |
| `AGENTCORE_TARGET_NAME` | No | `anycompanyDemoIVRApi` | AgentCore Target name |
| `PHASE2_STACK_NAME` | No | `${STACK_NAME}-phase2-qagents` | Phase 2 stack name |

---

## Deployment

### Deployment Order

The deployment is organized into phases with dependency ordering:

```
Phase 0 — Backend Infrastructure (no external dependencies)
  ├── 1. anycompany-ivr-client-config          (01a — Client config DynamoDB)
  ├── 2. anycompany-ivr-dynamodb               (01b — Core DynamoDB tables)
  ├── 3. anycompany-ivr-lambdas                (02a — 7 tool Lambdas)
  ├── 4. anycompany-ivr-fulfillment-hook       (02f — QinConnectDialogHook)
  └── 5. anycompany-ivr-getCallAttributes      (02b — getCallAttributes)

Phase 1 — Connect + AgentCore + Q in Connect
  └── 6. ${STACK_NAME} root                    (root.yaml — nested stacks)
         ├── ConnectInstanceStack               (connect-instance.yaml)
         ├── ConnectConfigStack                 (connect-config.yaml)
         ├── AgentCoreGatewayStack              (agentcore-gateway.yaml)
         ├── AgentCoreTargetStack               (agentcore-target.yaml)
         ├── BootstrapStack                     (bootstrap.yaml)
         └── McpApplicationStack                (mcp-application.yaml)

Phase 1b — Stacks requiring Connect Instance ARN
  ├── 7.  anycompany-ivr-payment-handoff       (02e — Payment infra + 4 Lambdas)
  ├── 8.  anycompany-ivr-payments-lambdas      (02d — 2 payment tool Lambdas)
  ├── 9.  anycompany-ivr-api                   (03 — API Gateway)
  ├── 10. anycompany-ivr-update-session        (02c — UpdateSessionData)
  └── 11. anycompany-ivr-agent-screen-pop      (agent-screen-pop-view.yaml)

═══ MANUAL STEPS (see below) ═══

Phase 2 — AI Agent Configuration
  └── 12. ${STACK_NAME}-phase2-qagents         (qagents-v49.yaml — 13 tool configs)

Post Phase 2 — Final Activation
  ├── Create AI Agent Version in Q console
  ├── Activate agent version
  └── End-to-end testing
```

### Running the Deployment

```bash
# 1. Clone the repository
git clone <repo-url>
cd anycompany-ivr

# 2. Configure environment
cp env.sh.example env.sh
# Edit env.sh with your values
source env.sh

# 3. Verify AWS credentials
aws sts get-caller-identity

# 4. Ensure S3 bucket exists
aws s3 mb s3://$BUCKET --region $REGION 2>/dev/null || true

# 5. Run deployment
chmod +x deploy-all.sh
./deploy-all.sh
```

The script will:
1. Deploy Phase 0 stacks (backend infra)
2. Upload nested templates to S3
3. Deploy Phase 1 root stack (Connect + AgentCore)
4. Deploy Phase 1b stacks (Connect-dependent resources)
5. **Pause for manual steps** (press ENTER when ready)
6. Deploy Phase 2 (AI Agent configuration)

### Manual Steps (Between Phase 1b and Phase 2)

The script will pause and display these steps. Complete them before pressing ENTER:

1. **Associate Q in Connect domain** with the Connect instance via console
2. **Verify MCP Server** is associated and tools are visible in Q tool picker
3. **Create ParkAndTollBot** (Lex V2):
   - Create bot with language `en_US`
   - Add `AmazonQinConnect` built-in intent
   - Set Fulfillment Code Hook → `anycompany-ivr-${ENVIRONMENT}-QinConnectDialogHook`
   - Build and publish bot
   - Associate with Connect instance
4. **Create PaymentCollectionBot** (Lex V2):
   - Create bot with `CollectPayment` intent (card number, expiry, CVV slots)
   - Add `CancelPayment` intent
   - Set Code Hook → `ivr-${ENVIRONMENT}-PaymentProcessing`
   - Build and publish bot
   - Associate with Connect instance
5. **Import Connect contact flows** from `connect-flows/` directory
6. **Deploy Lambda code** — replace CloudFormation stubs with actual function code
7. **Seed DynamoDB** with test data from `test-data/` directory
8. **Upload Knowledge Base docs** to S3 and trigger sync
9. **Claim phone number** in Connect and assign to inbound flow
10. **Verify tools** are visible and functional in Q console

---

## CloudFormation Stacks

### Stack Inventory

| Stack Name | Template | Resources Created |
|------------|----------|-------------------|
| `anycompany-ivr-client-config` | `01a-client-config-table.yaml` | Client config DynamoDB table (clientId PK, PhoneNumber-Index GSI) |
| `anycompany-ivr-dynamodb` | `01b-dynamodb-tables.yaml` | Customers, Violations, Disputes DynamoDB tables (PK/SK with GSIs) |
| `anycompany-ivr-lambdas` | `02a-tool-lambdas.yaml` | 7 tool Lambdas + IAM role (lookupByPlate, lookupByCitation, lookupByAccount, getBalance, getViolationDetails, submitDispute, checkDisputeStatus) |
| `anycompany-ivr-fulfillment-hook` | `02f-fulfillment-hook.yaml` | QinConnectDialogHook Lambda + IAM role |
| `anycompany-ivr-getCallAttributes` | `02b-getCallAttributes.yaml` | getCallAttributes Lambda + IAM role |
| `${STACK_NAME}` (root) | `root.yaml` | Nested: Connect instance, Q Assistant, KB, AI Prompt, AgentCore Gateway, Target, MCP App, Bootstrap |
| `anycompany-ivr-payment-handoff` | `02e-payment-handoff-resources.yaml` | KMS key, IVRSessionContext DynamoDB (with GSI + TTL), SSM params, 4 Lambdas (SaveAndRestoreSession, PaymentProcessing, UpdateViolationBalance, SeedPaymentSession) |
| `anycompany-ivr-payments-lambdas` | `02d-payments-lambdas.yaml` | 2 payment tool Lambdas (buildPaymentCart, initiatePayment) |
| `anycompany-ivr-api` | `03-api-gateway.yaml` | REST API, 9 endpoints, API key, usage plan, Lambda integrations |
| `anycompany-ivr-update-session` | `02c-ConnectAssistantUpdateSessionData.yaml` | UpdateSessionData Lambda (Node.js 20) + Connect integration |
| `anycompany-ivr-agent-screen-pop` | `agent-screen-pop-view.yaml` | Connect View + Contact Flow for agent escalation |
| `${STACK_NAME}-phase2-qagents` | `qagents-v49.yaml` | AWS::Wisdom::AIAgent with 13 tool configurations |

### Cross-Stack Dependencies

```
anycompany-ivr-client-config
  Exports: ClientConfigTableName, ClientConfigTableArn

anycompany-ivr-dynamodb
  Exports: CustomersTable, CustomersTableArn, ViolationsTable,
           ViolationsTableArn, DisputesTable, DisputesTableArn

anycompany-ivr-lambdas (imports from: dynamodb)
  Exports: ${stackName}-${env}-<FunctionName>FunctionArn (7 functions)

anycompany-ivr-payment-handoff (imports from: dynamodb)
  Exports: SessionTableName, SessionTableArn, SaveRestoreLambdaArn,
           PaymentProcessingLambdaArn, UpdateViolationBalanceLambdaArn,
           SeedPaymentSessionLambdaArn, KMSKeyArn

anycompany-ivr-payments-lambdas (imports from: dynamodb, payment-handoff)
  Exports: BuildPaymentCartFunctionArn, InitiatePaymentFunctionArn

anycompany-ivr-api (imports from: lambdas, payments-lambdas)
  Exports: ApiEndpoint, ApiId, ApiKeyId

root stack
  Exports: ConnectInstanceArn, ConnectInstanceId, AgentCoreGatewayId,
           AgentCoreTargetName, ToolNamePrefix, QInConnectAssistantId,
           QInConnectAssistantArn, OrchestrationPromptId
```

---

## DynamoDB Tables

| Table | Partition Key | Sort Key | GSIs | Template |
|-------|--------------|----------|------|----------|
| `client-config` | `clientId` (S) | — | `PhoneNumber-Index` (PhoneNumber → clientId) | 01a |
| `customers` | `PK` (S) | `SK` (S) | Multiple (plate, citation, account lookups) | 01b |
| `violations` | `PK` (S) | `SK` (S) | Multiple (account, status queries) | 01b |
| `disputes` | `PK` (S) | `SK` (S) | Multiple (account, status queries) | 01b |
| `IVRSessionContext` | `sessionId` (S) | `recordType` (S) | `initialContactId-index` (initialContactId + recordType), TTL enabled | 02e |

---

## Lambda Functions

### Tool Lambdas (Invoked by AI via AgentCore → API Gateway)

| Function | API Endpoint | Purpose | DynamoDB Table |
|----------|-------------|---------|----------------|
| `lookupByPlate` | `POST /account/lookup-by-plate` | Find customer by license plate | customers |
| `lookupByCitation` | `POST /account/lookup-by-citation` | Find customer by citation number | customers |
| `lookupByAccount` | `POST /account/lookup-by-account` | Find customer by account number | customers |
| `getBalance` | `POST /balance/get-balance` | Get account balance summary | violations |
| `getViolationDetails` | `POST /balance/get-violation-details` | Get specific violation details | violations |
| `submitDispute` | `POST /disputes/submit` | Submit a new dispute | disputes |
| `checkDisputeStatus` | `POST /disputes/status` | Check existing dispute status | disputes |
| `buildPaymentCart` | `POST /payments/build-cart` | Build payment cart from selected violations | IVRSessionContext |
| `initiatePayment` | `POST /payments/initiate` | Initiate payment handoff (ends AI conversation) | IVRSessionContext |

### Flow Helper Lambdas (Invoked by Connect Flows)

| Function | Invoked By | Purpose |
|----------|-----------|---------|
| `getCallAttributes` | Connect Flow (start) | Loads client config from DynamoDB at call start |
| `UpdateSessionData` | Connect Flow | Pushes contact attributes into Q in Connect session via Wisdom API |
| `QinConnectDialogHook` | Lex V2 (Fulfillment) | Sets `Tool` and `escalationReason` attributes for Connect routing |
| `SaveAndRestoreSession` | Connect Flow (payment) | Saves AI session before PCI handoff, restores after |
| `SeedPaymentSession` | Connect Flow (payment) | Prepares PaymentCollectionBot session with cart data |
| `PaymentProcessing` | Connect Flow (payment) | Processes card payment after PCI collection |
| `UpdateViolationBalance` | Connect Flow (payment) | Updates violation balances after successful payment |

---

## ToolName / ToolId Naming Convention

The AI Agent (QAgents) references MCP tools using two identifiers with different format requirements:

### ToolName (Q in Connect API requirement)
```
Format:  ${ToolNamePrefix}___<operationId>
Rule:    Only [a-zA-Z][a-zA-Z0-9_]* — NO HYPHENS
Example: anycompanyDemoIVRApi___lookupByPlate
```

### ToolId (Must match MCP registry entry)
```
Format:  gateway_${GatewayId}__${TargetName}___<operationId>
Rule:    Must exactly match AgentCore's auto-generated registry entry
Example: gateway_gw7f2a9b3c__anycompanyDemoIVRApi___lookupByPlate
```

### Delimiter Convention
```
gateway_abc123__myTarget___lookupByPlate
       ^       ^^         ^^^
       │       ││         │││
       │       ││         └┴┴── THREE underscores: target → operationId
       │       └┴── TWO underscores: gateway → target
       └── ONE underscore: literal "gateway_" prefix
```

### All 9 Tool Mappings

| operationId | ToolName | ToolId |
|-------------|----------|--------|
| `lookupByPlate` | `anycompanyDemoIVRApi___lookupByPlate` | `gateway_${GwId}__anycompanyDemoIVRApi___lookupByPlate` |
| `lookupByCitation` | `anycompanyDemoIVRApi___lookupByCitation` | `gateway_${GwId}__anycompanyDemoIVRApi___lookupByCitation` |
| `lookupByAccount` | `anycompanyDemoIVRApi___lookupByAccount` | `gateway_${GwId}__anycompanyDemoIVRApi___lookupByAccount` |
| `getBalance` | `anycompanyDemoIVRApi___getBalance` | `gateway_${GwId}__anycompanyDemoIVRApi___getBalance` |
| `getViolationDetails` | `anycompanyDemoIVRApi___getViolationDetails` | `gateway_${GwId}__anycompanyDemoIVRApi___getViolationDetails` |
| `submitDispute` | `anycompanyDemoIVRApi___submitDispute` | `gateway_${GwId}__anycompanyDemoIVRApi___submitDispute` |
| `checkDisputeStatus` | `anycompanyDemoIVRApi___checkDisputeStatus` | `gateway_${GwId}__anycompanyDemoIVRApi___checkDisputeStatus` |
| `buildPaymentCart` | `anycompanyDemoIVRApi___buildPaymentCart` | `gateway_${GwId}__anycompanyDemoIVRApi___buildPaymentCart` |
| `initiatePayment` | `anycompanyDemoIVRApi___initiatePayment` | `gateway_${GwId}__anycompanyDemoIVRApi___initiatePayment` |

---

## API Gateway Endpoints

**Base URL**: `https://<api-id>.execute-api.us-east-1.amazonaws.com/${API_STAGE}`

**Authentication**: API Key via `X-API-Key` header

| Method | Path | Lambda | Description |
|--------|------|--------|-------------|
| POST | `/account/lookup-by-plate` | lookupByPlate | Lookup customer by license plate |
| POST | `/account/lookup-by-citation` | lookupByCitation | Lookup customer by citation number |
| POST | `/account/lookup-by-account` | lookupByAccount | Lookup customer by account number |
| POST | `/balance/get-balance` | getBalance | Get account balance summary |
| POST | `/balance/get-violation-details` | getViolationDetails | Get specific violation details |
| POST | `/disputes/submit` | submitDispute | Submit new dispute |
| POST | `/disputes/status` | checkDisputeStatus | Check dispute status |
| POST | `/payments/build-cart` | buildPaymentCart | Build payment cart |
| POST | `/payments/initiate` | initiatePayment | Initiate payment (triggers PCI handoff) |

All endpoints also support `OPTIONS` for CORS preflight.

---

## Teardown

To delete all stacks in reverse dependency order:

```bash
# Phase 2
aws cloudformation delete-stack --stack-name ${STACK_NAME}-phase2-qagents --region $REGION
aws cloudformation wait stack-delete-complete --stack-name ${STACK_NAME}-phase2-qagents --region $REGION

# Phase 1b (reverse order)
aws cloudformation delete-stack --stack-name anycompany-ivr-agent-screen-pop --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-update-session --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-api --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-payments-lambdas --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-payment-handoff --region $REGION

# Wait for all Phase 1b deletions
for stack in anycompany-ivr-agent-screen-pop anycompany-ivr-update-session \
             anycompany-ivr-api anycompany-ivr-payments-lambdas anycompany-ivr-payment-handoff; do
  aws cloudformation wait stack-delete-complete --stack-name $stack --region $REGION 2>/dev/null
done

# Phase 1 (root — deletes all nested stacks)
aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION

# Phase 0
aws cloudformation delete-stack --stack-name anycompany-ivr-getCallAttributes --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-fulfillment-hook --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-lambdas --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-dynamodb --region $REGION
aws cloudformation delete-stack --stack-name anycompany-ivr-client-config --region $REGION

echo "All stacks deleted."
```

> **Note**: DynamoDB tables with `DeletionPolicy: Retain` will persist after stack deletion. Delete them manually if needed.

### Manual Cleanup

After stack deletion, also remove:
- Connect phone number claims
- Lex V2 bots (ParkAndTollBot, PaymentCollectionBot)
- Q in Connect domain association
- S3 bucket contents (templates, KB docs)
- CloudWatch Log Groups (retained by default)

---

## Troubleshooting

### Common Issues

| Issue | Cause | Resolution |
|-------|-------|------------|
| `REGION: set REGION` error on script start | Required env var not set | Run `source env.sh` before `./deploy-all.sh` |
| Phase 1 nested stack fails with S3 access error | S3 bucket doesn't exist or wrong region | Create bucket: `aws s3 mb s3://$BUCKET --region $REGION` |
| Q in Connect tools not visible | MCP Server not associated | Associate MCP Server in Q console → Tools section |
| AI agent doesn't invoke tools | ToolId mismatch with MCP registry | Verify ToolId format matches `gateway_<GwId>__<TargetName>___<opId>` |
| Payment flow fails silently | IVRSessionContext table missing GSI | Verify `initialContactId-index` GSI exists on table |
| Lex fulfillment returns empty | Dialog hook Lambda not configured | Set QinConnectDialogHook as Fulfillment Code Hook on AmazonQinConnect intent |
| Connect flow can't invoke Lambda | Missing Lambda invoke permission | Verify `AWS::Lambda::Permission` with `connect.amazonaws.com` principal |
| API Gateway returns 403 | API key not sent or invalid | Verify `X-API-Key` header matches the provisioned key |
| AgentCore target creation fails | OpenAPI spec not in S3 | Upload: `aws s3 cp cfn/openapi.yaml s3://$BUCKET/$PREFIX/openapi.yaml` |

### Validating Tool Registration

After Phase 1 deployment, verify tools are registered in AgentCore:

```bash
# Get Gateway ID
GATEWAY_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query "Stacks[0].Outputs[?OutputKey=='AgentCoreGatewayId'].OutputValue" \
  --output text --region $REGION)

# List targets
aws bedrock-agent-core list-gateway-targets \
  --gateway-identifier $GATEWAY_ID \
  --region $REGION

# Verify tools are discoverable
aws bedrock-agent-core list-tools \
  --gateway-identifier $GATEWAY_ID \
  --region $REGION
```

### Checking CloudFormation Stack Status

```bash
# List all project stacks
aws cloudformation list-stacks --region $REGION \
  --query "StackSummaries[?starts_with(StackName,'anycompany-ivr') && StackStatus!='DELETE_COMPLETE'].[StackName,StackStatus]" \
  --output table

# Check specific stack events (for debugging failures)
aws cloudformation describe-stack-events \
  --stack-name anycompany-ivr-api \
  --region $REGION \
  --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
  --output table
```

---

## Known Limitations

1. **Lex V2 bots require manual setup** — CloudFormation support for Lex V2 + Q in Connect integration is limited
2. **Connect contact flows require manual import** — Flow JSON must be imported via console or API
3. **Region locked to us-east-1** — Amazon Q in Connect with Nova Sonic is only available in us-east-1
4. **AI Agent version activation is manual** — After Phase 2 deployment, version must be created and activated in Q console
5. **OpenAPI spec contains hardcoded server URL** — Must be updated per environment after API Gateway deployment
6. **Lambda code deploys as stubs** — Actual function code must be deployed separately after stack creation

---

## Security Considerations

- **PCI Compliance**: Card data is collected exclusively by PaymentCollectionBot in a separate Lex session; AI agent never accesses card details
- **KMS Encryption**: Payment session data in IVRSessionContext is encrypted with a dedicated KMS key
- **API Key Authentication**: All tool Lambda invocations go through API Gateway with API key validation
- **IAM Least Privilege**: Each Lambda has its own IAM role with only required permissions
- **Session TTL**: IVRSessionContext records expire automatically via DynamoDB TTL
- **No credentials in code**: AgentCore API key is provisioned via custom resource (bootstrap) and stored as a credential provider

---

## License

[Your License Here]

---

## Contributors

[Your Team Here]
```

This README covers the complete project. Let me know if you'd like me to adjust any section — add more detail to a specific area, add architectural decision records (ADRs), or create supplementary documentation like a runbook or testing guide.