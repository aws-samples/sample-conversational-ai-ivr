# Manual Post Phase 1 & Phase 2 Deployment Steps

**Document Version:** 1.0  
**Date:** 2026-04-06

These steps must be executed **between and after** the automated Phase 1 and Phase 2 deployments. They cover manual configurations that cannot be fully automated due to console-only operations, dependency ordering, or runtime-generated values.

---

## Post Phase 1 Deployment Steps

Execute these steps after `deploy-all.sh` completes Phase 1 and Phase 1b, **before** proceeding to Phase 2.

---

### Step 1: Associate Q in Connect Domain with Connect Instance

1. Navigate to the **Amazon Connect console**
2. Select your Connect instance (`anycompany-ivr-demo-2`)
3. In the left navigation, choose **Connect Assistant** or **Amazon Q** → **Add domain**
4. Select **Use an existing domain**
5. Choose the domain from the dropdown and click **Add domain**

**Add Knowledge Base Integration:**

1. On the **Add integration** page, choose **Create a new integration** → select **S3** as the source
2. Integration name: `anycompanyIVRDemo`
3. Under **Connection with S3**, browse and select your KB bucket: `anycompany-kb-bucket-3966`
4. Once created, upload the following files to the S3 bucket:
   - `knowledge-base/faq.txt`
   - `knowledge-base/policies.txt`
   - `knowledge-base/services.txt`

---

### Step 2: Verify OpenAPI Schema Location

The AgentCore Gateway Target requires the OpenAPI schema file at the root of the S3 bucket.

Verify it was uploaded correctly during Phase 1:
```bash
aws s3 ls s3://cf-templates-1ioo9aupbz9zw-us-east-1/anycompany-ivr/templates/openapi.yaml
```

---

### Step 3: Update AgentCore Gateway Inbound Audience

1. Open the **Bedrock AgentCore** console
2. Navigate to your gateway (`c001-ivr-mcp-gw-*`)
3. Copy the **Gateway ID** from the Gateway details section
4. Click **Edit** on the **Inbound Identity** section
5. Paste the Gateway ID in the **Audiences** text box
6. Ensure **Allowed clients** is **unchecked**
7. Save your changes

---

### Step 4: Configure MCP Integration (Replace Auto-Deployed One)

The MCP application deployed by automation may not work correctly. Replace it manually:

1. Open **Amazon Connect Console** → **Third-party applications** (left navigation)
2. **Delete** the existing MCP application that was deployed by automation
3. Click **Add application**
4. Configure:
   - **Display name:** `anycompany-IVR-mcp`
   - **Description:** `MCP server for Anycompany Park and Tolling API`
   - **Application type:** Select **MCP server**
   - The gateway will automatically be available to select
5. Select your Connect instance in the **Instance association** section
6. Save

---

### Step 5: Create Admin User

Run the admin user creation script:

```bash
python3 create_connect_admin.py \
  --region us-east-1 \
  --instance-id "${CONNECT_INSTANCE_ID}" \
  --username "admin" \
  --password '<your-password>' \
  --email "<your-email>" \
  --first-name "Admin" \
  --last-name "User"
```

---

### Step 6: Access Admin Interface and Create Security Profile

1. In the Amazon Connect console, click **Overview** in the left navigation
2. Find the **Access URL** and open it in a new tab
3. Log in with the credentials from Step 5

**Create Security Profile:**

1. Click **Users** → **Security profiles** → **Add new security profile**
2. Configure:
   - **Name:** `ParkandToll-AI-Agent`
   - **Description:** `Security profile for AI agents handling Parking and Tolling`
3. Set permissions:
   - **Contact Control Panel (CCP):** Select "Access Contact Control Panel"
   - **Agent Applications:** Select "Connect assistant - View"
   - **Tools:** Select "Access" for all MCP tools:
     - `anycompanyDemoIVRApi___buildPaymentCart`
     - `anycompanyDemoIVRApi___checkDisputeStatus`
     - `anycompanyDemoIVRApi___getBalance`
     - `anycompanyDemoIVRApi___getViolationDetails`
     - `anycompanyDemoIVRApi___initiatePayment`
     - `anycompanyDemoIVRApi___lookupByAccount`
     - `anycompanyDemoIVRApi___lookupByCitation`
     - `anycompanyDemoIVRApi___lookupByPlate`
     - `anycompanyDemoIVRApi___submitDispute`
     - `anycompanyDemoIVRApi___applyPaymentResult`
4. Click **Save**

---

## Phase 2 Deployment

At this point, return to the `deploy-all.sh` script and press ENTER to proceed with Phase 2 (AI Agent Configuration). Wait for it to complete.

---

## Post Phase 2 Deployment Steps

Execute these steps after Phase 2 (`anycompany-ivr-phase2-qagents`) completes.

---

### Step 7: Update AI Agent Prompt

1. Log in to the Connect Admin interface (or refresh if already logged in)
2. Navigate to **AI agent designer** → **AI Agents**
3. Find the agent: `<Instance_Alias>-orchestration-agent`
4. Click **Edit in Agent Builder**
5. Edit the AI Prompt and replace it with the content from `ai-agent/Final-System-Prompt-03242026_1230.txt`
6. Click **Save** then **Publish**
7. Go back to the Agent → **Add Prompt** → **Add existing AI Prompt** → select the v2 prompt you just saved

---

### Step 8: Set Default AI Agent

1. Navigate to **AI agent designer** → **AI Agents**
2. Scroll to **Default AI Agent Configurations**
3. In the **Self-service** row, select `<Instance_Alias>-orchestration-agent` from the dropdown
4. Click the checkmark to save

---

### Step 9: Enable Bot Management in Connect

1. Open the **Amazon Connect console** → select your instance
2. Navigate to **Flows** in the left menu
3. Locate **Enable Lex Bot Management in Amazon Connect**:
   - Turn it **OFF** → click **Save**
   - Turn it back **ON** → click **Save**
4. Ensure both are enabled:
   - ✅ Enable Lex Bot Management in Amazon Connect
   - ✅ Enable Bot Analytics and Transcripts in Amazon Connect
5. Click **Save**

---

### Step 10: Associate Lambdas with Connect Instance

Ensure `CONNECT_INSTANCE_ID` is set in `env.sh`, then run:

```bash
./scripts/associate_lamnbda_to_connect.sh
```

This associates the following Lambdas:
- `ConnectAssistantUpdateSessionDataNew`
- `anycompany-ivr-dev-getCallAttributes`
- `ivr-dev-SeedPaymentSession`
- `ivr-dev-SaveAndRestoreSession`
- `ivr-dev-UpdateViolationBalance`

---

### Step 11: Create ParkAndTollBot

```bash
./create-park-and-toll-bot.sh
```

Verify the output shows:
- ✅ FulfillmentCodeHook enabled on AmazonQInConnect intent
- ✅ Lambda ARN configured on alias locale settings
- ✅ Lambda resource policy allows lexv2.amazonaws.com

---

### Step 12: Create PaymentCollectionBot

```bash
./create-payment-bot.sh
```

Note the Bot ID and Alias ID from the output (also saved to `payment-bot-config.json`).

---

### Step 13: Redeploy Payment Handoff Stack with Real Bot IDs

The `02e` stack was deployed with `PENDING` bot IDs. Redeploy with real values:

```bash
BOT_ID=$(python3 -c "import json; print(json.load(open('payment-bot-config.json'))['botId'])")
ALIAS_ID=$(python3 -c "import json; print(json.load(open('payment-bot-config.json'))['botAliasId'])")

aws cloudformation deploy --region us-east-1 \
  --stack-name anycompany-ivr-payment-handoff \
  --template-file cfn/standalone/02e-payment-handoff-resources.yaml \
  --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset \
  --parameter-overrides \
    Environment=dev \
    DynamoDBStackName=anycompany-ivr-dynamodb \
    SessionTableStackName=anycompany-ivr-session-table \
    ConnectInstanceArn=arn:aws:connect:us-east-1:${ACCOUNT_ID}:instance/${CONNECT_INSTANCE_ID} \
    PaymentBotId=$BOT_ID \
    PaymentBotAliasId=$ALIAS_ID
```

---

### Step 14: Fix Contact Flow Placeholders and Import

**A) Fix placeholders in the local flow JSON:**

```bash
./fix-connect-flow.sh connect-flows/main-ivr-flow.json
```

**B) Manually update the `WisdomAssistantArn`** in the updated JSON with the actual ARN from Phase 1 outputs.

**C) Also update the PaymentCollectionBot ARN** in the flow JSON with the bot ID and alias ID from Step 12.

**D) Import flows in order:**

1. **Basic-setting-configurations.json** (flow module):
   - Connect Admin → **Routing** → **Flows** → **Modules** tab
   - Click **Create flow module** → dropdown **Import**
   - Select `basic-setting-configurations.json`

2. **Main Flow** (`main-ivr-flow.json`):
   - Connect Admin → **Routing** → **Flows**
   - Click **Create contact flow** → dropdown **Import (JSON)**
   - Select the updated flow from `flow-updates/flow-updated-*.json`
   - Click **Save** then **Publish**

---

### Step 15: Deploy Lambda Code from Local

```bash
./scripts/update-lambda-code.sh
```

Verify all 16 functions show ✅ in the final verification table.

---

### Step 16: Update initiatePayment Lambda Environment Variable

The `CONNECT_INSTANCE_ID` env var may not be set correctly:

```bash
# Get current env vars and update
aws lambda get-function-configuration \
  --function-name anycompany-ivr-initiate-payment-dev \
  --region us-east-1 --query "Environment.Variables" --output json

# Update with correct Connect Instance ID
aws lambda update-function-configuration \
  --function-name anycompany-ivr-initiate-payment-dev \
  --region us-east-1 \
  --environment "{\"Variables\": $(aws lambda get-function-configuration \
    --function-name anycompany-ivr-initiate-payment-dev \
    --region us-east-1 --query "Environment.Variables" --output json \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['CONNECT_INSTANCE_ID']='${CONNECT_INSTANCE_ID}'; print(json.dumps(d))")}"
```

---

### Step 17: Seed DynamoDB Test Data

```bash
python3 scripts/utilities/seed_client_config.py
python3 scripts/utilities/seed_test_data.py
```

---

### Step 18: Claim Phone Number

1. Connect Admin → **Channels** → **Phone numbers** → **Claim a number**
2. Select a number and assign it to the **Main Flow**

---

### Step 19: Update Client Config with Claimed Phone Number

```bash
./scripts/utilities/update-client-phone.sh +1XXXXXXXXXX
```

Replace `+1XXXXXXXXXX` with the phone number claimed in Step 18 (E.164 format).

---

### Step 20: Update Escalate Tool on AI Agent

See [MANUAL_POST_DEPLOYMENT_STEPS.md — Step 3](MANUAL_POST_DEPLOYMENT_STEPS.md#step-3-update-escalate-tool-input-schema-and-instructions-on-ai-agent) for the full input schema, instructions, and examples to configure manually in the console.

---

### Step 21: Add Retrieve Tool to AI Agent

See [MANUAL_POST_DEPLOYMENT_STEPS.md — Step 4](MANUAL_POST_DEPLOYMENT_STEPS.md#step-4-add-retrieve-tool-to-ai-agent) for the full walkthrough to add the Knowledge Base Retrieve tool manually in the console.

---

### Step 22: End-to-End Test

Call the claimed phone number and verify:

- [ ] AI greets correctly with client-specific greeting
- [ ] Provide license plate → AI looks up account
- [ ] Ask about violations → AI retrieves details
- [ ] Ask a policy question → AI uses RETRIEVE tool for KB search
- [ ] Request payment → AI builds cart → initiatePayment triggers
- [ ] Fulfillment Lambda detects payment transfer
- [ ] Route to PaymentCollectionBot → collect card details
- [ ] Payment processed → resume AI conversation
- [ ] Request agent → Escalate to queue with context

---

## Troubleshooting

If you encounter issues during these steps, refer to:
- [Known Issues](KNOWN_ISSUES.md) — documented deployment issues and fixes
- [Troubleshooting Guide](troubleshooting.md) — general troubleshooting steps

### Common Issues at This Stage

| Symptom | Likely Cause | Fix |
|---|---|---|
| AI says nothing / immediate disconnect | AgentCore Gateway permissions | Run `fix-agentcore-gateway-policies-complete.sh` |
| Tool calls return 403 | API Key required on API Gateway | Redeploy `03-api-gateway.yaml` with `ApiKeyRequired: false` |
| Lambda KMS AccessDeniedException | Missing KMS policy on Lambda role | Run `scripts/fix-lambda-kms-permissions.sh` |
| Payment flow doesn't trigger | `successNextStep` set to `EndConversation` | Recreate ParkAndTollBot with fixed script |
| SeedPaymentSession fails with lex:PutSession | Bot IDs still `PENDING` | Redeploy `02e` stack with real bot IDs (Step 13) |
