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
3. In the left navigation, choose **Applicatons → AI Agents → **Add domain**
4. Select **Use an existing domain**
5. Choose the domain (<instance_alias>-assistant) from the dropdown and click **Add domain**

**Add Knowledge Base Integration:**

1. Select the existing integration and **Delete** it. 
2. On the **Add integration** page, choose **Create a new integration** → select **S3** as the source
3. Integration name: `anycompanyIVRDemo`
4. Under **Connection with S3**, browse and select your KB bucket: `anycompany-kb-bucket-xxx`
5. Under Encryption, select "AWS KMS key" - **ivr-dev-payment-key**
6. Click "Next" and **Add Integration**
5. Once created, upload the following files to the S3 bucket:
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
2. **Delete** the existing MCP application (mcp_tools) that was deployed by automation
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

Run the admin user creation script: Make sure to update the env.sh with the connect Instance ID creaated earlier.

```bash
source env.sh
# NOTE: Replace 'python3' with 'python' if that is the command in your environment.
# Run 'python3 --version' or 'python --version' to confirm which is available.
python3 scripts/utilities/create_connect_admin.py \
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

### Step 7: Create AI Agent Manually

> **Note:** The AI agent auto-deployed by Phase 2 (`<Instance_Alias>-orchestration-agent`) is currently **not working** and can be ignored. You must create a new agent manually using the steps below.

**Create the Agent:**

1. In the Connect Admin interface, click **AI agent designer** in the left navigation
2. Click **AI agents** to view AI agents
3. Click **Create AI agent**
4. Configure:
   - **Name:** `anycompany-ivr-agent`
   - **AI Agent type:** Select **Orchestration**
   - **Copy from existing:** Select **SelfServiceOrchestrator**
   - **Description:** `AI agent for handling Parking and Tolling Services at AnyCompany`
5. Click **Create**

**Configure Basic Settings:**

1. Set the **locale:** English (US)
2. Select the **security profile:** `ParkandToll-AI-Agent` (created in Step 6)
3. **Save** your AI Agent to apply the security profile

**Create the AI Prompt**

1. In the Connect Admin interface, click **AI agent designer** in the left navigation
2. Click **AI prompts** to view AI agents
3. Click **Create AI Prompt**
4. Configure:
   - **Name:** `IVRDemo-AI-Agent-System-Prompt`
   - **AI Prompt type** `Orchestration`
   - **Description:** `System Prompt for AI Agent`
5. Click **Create**
6. Once created, Edit the AI Prompt and replace it with the content from `ai-agent/Final-System-Prompt-03242026_1230.txt`
7. Click **Save** and then **Publish**
8. Go back to **AI agent designer**, select the agent created earlier and click **Edit in Agent Builder**
9. Navigate to **Promppt** section and click **Add Prompt**
10. Select **Add existing AI Prompt** and select the one created earlier
11. Click **Add** and then **Save**


**Add MCP Tools:**

1. Click **Add tool** in the **Tools** tab
2. Select a **Namespace** from the dropdown: `gateway_XXXX-{shortcode}` (your AgentCore gateway)
3. Select the AI tool from the dropdown
4. Check the **User Confirmation** toggle if you want the agent to confirm details with the customer before executing
5. Scroll to the bottom and click **Add**
6. Repeat for all tools:
   - `anycompanyDemoIVRApi___applyPaymentResult`
   - `anycompanyDemoIVRApi___buildPaymentCart`
   - `anycompanyDemoIVRApi___checkDisputeStatus`
   - `anycompanyDemoIVRApi___getBalance`
   - `anycompanyDemoIVRApi___getViolationDetails`
   - `anycompanyDemoIVRApi___initiatePayment`
   - `anycompanyDemoIVRApi___lookupByAccount`
   - `anycompanyDemoIVRApi___lookupByCitation`
   - `anycompanyDemoIVRApi___lookupByPlate`
   - `anycompanyDemoIVRApi___submitDispute`

---

### Step 8: Set Default AI Agent

1. Navigate to **AI agent designer** → **AI Agents**
2. Scroll to **Default AI Agent Configurations**
3. In the **Self-service** row, select **`anycompany-ivr-agent`** (the agent you just created) from the dropdown
4. Click the checkmark to save

> **Important:** Do NOT select the auto-deployed `<Instance_Alias>-orchestration-agent` — use the manually created `anycompany-ivr-agent` instead.

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
source env.sh
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

> **Note:** Ensure your current working directory is the **project root folder** (where `env.sh` is located).

```bash
./create-park-and-toll-bot.sh
```

Verify the output shows:
- ✅ FulfillmentCodeHook enabled on AmazonQInConnect intent
- ✅ Lambda ARN configured on alias locale settings
- ✅ Lambda resource policy allows lexv2.amazonaws.com

---

### Step 12: Create PaymentCollectionBot

> **Note:** Ensure your current working directory is the **project root folder** (where `env.sh` is located).

```bash
./create-payment-bot.sh
```

Note the Bot ID and Alias ID from the output (also saved to `payment-bot-config.json`).

---

### Step 13: Redeploy Payment Handoff Stack with Real Bot IDs

The `02e` stack was deployed with `PENDING` bot IDs. Redeploy with real values:
Make sure CONNECT_INSTANCE_ID is updated in env.sh

```bash
source env.sh
# NOTE: Replace 'python3' with 'python' if that is the command in your environment.
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

**B) Manually update the `WisdomAssistantArn`** in the (Basic-setting-configurations.json) with the actual ARN from Phase 1 outputs.

**C) Also update the PaymentCollectionBot ARN** in the updated flow JSON with the bot ID and alias ID from Step 12. Search for every occurence of **123456789012** and replace it with actual value


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

## Connect Flow Update Process

### Problem

When Amazon Connect contact flows are imported or created from templates, they may contain placeholder ARNs — references to resources that use a dummy AWS account ID (e.g., `123456789012`) or placeholder resource identifiers (e.g., `PARK_BOT_ID_PLACEHOLDER`). These placeholder ARNs prevent the flow from functioning correctly at runtime, even though the Connect visual editor may display the correct resource names in the dropdown selections.

Symptoms of placeholder ARNs:

- Caller hears "Thank you for calling. Goodbye." immediately
- Lex bot blocks return instantly without engaging the AI agent
- Lambda invocations fail silently (error paths are followed)
- Contact flow appears correct in the visual editor but fails at runtime

### How the Fix Script Works

The `fix-contact-flow.sh` script automates the replacement of all placeholder ARNs with real deployed resource ARNs. It reads environment configuration from `env.sh` and performs the following steps:

```
┌──────────────────────────────────┐
│  1. Source env.sh                │  Reads REGION, ACCOUNT_ID,
│     Validate required variables  │  CONNECT_INSTANCE_ID
├──────────────────────────────────┤
│  2. Discover real resource ARNs  │  Looks up ParkAndTollBot (bot ID + alias)
│                                  │  Fetches all Lambda function ARNs
├──────────────────────────────────┤
│  3. Export the contact flow      │  Downloads current flow JSON from Connect
│     Save original as backup      │  Counts placeholder references
├──────────────────────────────────┤
│  4. Replace placeholder ARNs     │  Lex bot: PARK_BOT_ID_PLACEHOLDER → real
│                                  │  Lambdas: 123456789012 → real account ID
├──────────────────────────────────┤
│  5. Show diff and confirm        │  Displays before/after changes
│                                  │  Prompts for confirmation
├──────────────────────────────────┤
│  6. Update and publish flow      │  Pushes updated JSON to Connect
│                                  │  Sets flow state to ACTIVE
├──────────────────────────────────┤
│  7. Verify                       │  Re-exports flow, confirms zero
│     Export verified flow         │  placeholders remain
└──────────────────────────────────┘
```

### Prerequisites

Ensure `env.sh` exists in the project root with the following variables:

```bash
# env.sh
export REGION="us-east-1"
export ACCOUNT_ID="123456789012"           # Your real AWS account ID
export CONNECT_INSTANCE_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

The following resources must already be deployed:

- Amazon Connect instance with the contact flow imported
- ParkAndTollBot (Lex V2) with a `live` alias
- All Lambda functions deployed via CloudFormation stacks

### Usage

```bash
# Make the script executable (first time only)
chmod +x fix-contact-flow.sh

# Run the script
./fix-contact-flow.sh
```

### What Gets Replaced

The script automatically detects and replaces the following placeholder patterns:

| Resource Type | Placeholder Pattern | Replaced With |
|---|---|---|
| Lex Bot (ParkAndTollBot) | `arn:aws:lex:REGION:123456789012:bot-alias/PARK_BOT_ID_PLACEHOLDER/PARK_BOT_ALIAS_PLACEHOLDER` | Real bot-alias ARN discovered via `lexv2-models` API |
| Lambda Functions | `arn:aws:lambda:REGION:123456789012:function:FUNCTION_NAME` | Real Lambda ARN discovered via `lambda list-functions` API |

Lambda functions resolved automatically:

| Flow Block | Placeholder Function Name | Real Function |
|---|---|---|
| Update Connect session data Lambda | `ConnectAssistantUpdateSessionDataNew` | Auto-discovered |
| Save Session for Payment | `ivr-dev-SaveAndRestoreSession` | Auto-discovered |
| Restore Session Lambda | `ivr-dev-SaveAndRestoreSession` | Auto-discovered |
| Update Violation Balance | `ivr-dev-UpdateViolationBalance` | Auto-discovered |
| Seed Payment Bot Session | `ivr-dev-SeedPaymentSession` | Auto-discovered |

> **Note:** The script discovers placeholder function names directly from the flow JSON and resolves them against your deployed Lambda functions. No manual ARN mapping is required.

### Output Files

All files are saved to the `flow-updates/` directory:

| File | Description |
|---|---|
| `flow-original-TIMESTAMP.json` | Backup of the flow before any changes |
| `flow-updated-TIMESTAMP.json` | The flow with placeholders replaced (pre-publish) |
| `flow-verified-TIMESTAMP.json` | Re-exported flow after publishing (post-verification) |

### Example Output

```
╔══════════════════════════════════════════════════════╗
║   Contact Flow ARN Fix                               ║
║   Replace placeholder ARNs with real deployed ARNs   ║
╚══════════════════════════════════════════════════════╝

  Environment (from env.sh):
    Region:              us-east-1
    Account ID:          123456789012
    Connect Instance ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Flow Name:           Main Flow

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 1: Discovering Real Resource ARNs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ ParkAndTollBot ARN: arn:aws:lex:us-east-1:123456789012:bot-alias/XXXXXXXX/YYYYYYYY
  ✅ Found 18 Lambda functions in account

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  STEP 3: Replacing Placeholder ARNs
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Replaced 2 Lex bot placeholder(s)
  ✅ Replaced Lambda (2x): ivr-dev-SaveAndRestoreSession
  ✅ Replaced Lambda (1x): ivr-dev-UpdateViolationBalance
  ✅ Replaced Lambda (1x): ConnectAssistantUpdateSessionDataNew
  ✅ Replaced Lambda (1x): ivr-dev-SeedPaymentSession
  ✅ All placeholders replaced successfully! ✨

  Apply changes and publish? (y/N): y

  ✅ Contact flow content updated!
  ✅ Contact flow is ACTIVE and PUBLISHED!

  ┌───────────────────────────────────────────────────────┐
  │ Verification Results                                   │
  ├───────────────────────────────────────────────────────┤
  │  Placeholder account refs:  0    (should be 0)        │
  │  PLACEHOLDER strings:       0    (should be 0)        │
  │  Real account refs:         12   (should be > 0)      │
  └───────────────────────────────────────────────────────┘

  ╔══════════════════════════════════════════════════════╗
  ║  ✅ CONTACT FLOW UPDATED SUCCESSFULLY!              ║
  ║  🎉 Test it now — call your phone number!           ║
  ╚══════════════════════════════════════════════════════╝
```

### Customization

The script supports optional environment variables for non-default configurations:

```bash
# Override defaults (set in env.sh or export before running)
export FLOW_NAME="Main Flow"                    # Default: "Main Flow"
export PLACEHOLDER_ACCOUNT="123456789012"       # Default: "123456789012"
export PARK_BOT_NAME="ParkAndTollBot"           # Default: "ParkAndTollBot"
export PARK_BOT_ALIAS_NAME="live"               # Default: "live"
```

### Idempotency

The script is safe to run multiple times:

- If no placeholders are found, it exits early with a success message
- Original flow is always backed up before changes
- Changes require explicit confirmation before being applied
- Post-publish verification ensures the update was applied correctly

---

### Step 15: Deploy Lambda Code from Local

```bash
./update-lambda-code.sh
```

Verify all 16 functions show ✅ in the final verification table.

---

### Step 16: Update initiatePayment Lambda Environment Variable

> **Note:** Make sure to `source env.sh` first so that `$CONNECT_INSTANCE_ID` is available in your shell.

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
# NOTE: Replace 'python3' above with 'python' if that is the command in your environment.
```

---

### Step 17: Seed DynamoDB Test Data

```bash
# NOTE: Replace 'python3' with 'python' if that is the command in your environment.
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

The CFN-deployed Escalate tool has a minimal schema with only a `reason` field. It must be updated manually via the Amazon Q in Connect console with the full schema, instructions, and examples.

**Navigate to the Escalate tool:**

1. In the Connect Admin console, go to **AI agent designer** → **AI agents**
2. Click on `anycompany-ivr-agent` → **Edit in Agent Builder**
3. Find the **Escalate** tool and click **Edit**

**Replace the Input Schema with:**

```json
{
  "type": "object",
  "properties": {
    "customerIntent": {
      "type": "string",
      "description": "A brief phrase (10-15words) describing what the customer wants to accomplish"
    },
    "sentiment": {
      "type": "string",
      "description": "Customer's emotional state during the conversation",
      "enum": ["positive", "neutral", "frustrated"]
    },
    "escalationSummary": {
      "type": "string",
      "description": "Detailed summary for the human agent including what the customer asked for, what was attempted, and why escalation is needed",
      "maxLength": 500
    },
    "escalationReason": {
      "type": "string",
      "description": "Category for the escalation reason",
      "enum": ["complex_booking", "technical_issue", "customer_frustration", "policy_exception", "out_of_scope", "other"]
    }
  },
  "required": ["escalationReason", "escalationSummary", "customerIntent", "sentiment"]
}
```

**Replace the Instructions with:**

```
Escalate to a human agent when:

**Volume & Complexity Triggers:**
1. Request involves more than 3 vehicles or license plates
2. Request involves more than 5 violations to address
3. Request involves multiple accounts (personal + business, duplicate accounts needing merger)
4. Fleet or commercial account management is needed

**Specialized Expertise Required:**
5. Estate settlement or deceased account holder situations
6. Commercial account setup with custom requirements (emergency exemptions, multi-user access, custom invoicing)
7. Rental car billing disputes involving multiple rental companies
8. Vehicle ownership transfers for multiple vehicles
9. Account migration or system transition issues
10. Requests requiring legal documentation (court cases, probate, tax audits)

**Multi-Domain Coordination:**
11. Combined parking and toll issues in one request
12. Disputes requiring evidence review (dashcam footage, photos, documents)
13. Payment investigations requiring bank coordination
14. Requests needing coordination across multiple departments

**System & Satisfaction Issues:**
15. Multiple tools fail or return errors repeatedly
16. Knowledge base lacks required policy information
17. Customer expresses frustration, dissatisfaction, or explicitly requests a human
18. You cannot provide adequate assistance with available tools

When escalating, acknowledge the complexity or importance of their request, briefly summarize what you understood (to show you listened), and reassure them that the specialist will have all the context to help efficiently.
```

**Add Examples:**

Good example — Complex coordination request:
```
<message>
I understand you had a difficult day - a parking ticket from an app issue and a toll violation from police-directed traffic, and you have dashcam footage of both. Since this involves both our parking and toll systems with video evidence to review, plus the documentation you need for work reimbursement, let me connect you with a specialist who can coordinate everything and get you the proper receipts.
</message>
```

Good example — Technical difficulties:
```
<message>
I apologize, but I'm experiencing technical difficulties right now. To make sure you get accurate information, let me connect you with a representative who can help you directly right away.
</message>
```

Good example — Frustrated customer:
```
<message>
I'm really sorry for all the trouble you've been through. That's not the experience you should have. Let me get you to someone who can resolve this and make sure this gets handled properly.
</message>
```

Good example — Complex fleet coordination:
```
<message>
Setting up a fleet account with multiple ownership types, separate billing categories, and custom access levels is exactly what our commercial accounts team handles. They can coordinate the transponder shipments to your three locations and configure everything to meet your two-week deadline. Let me connect you with a business account specialist right away.
</message>
```

Bad example (avoid — too abrupt, no empathy):
```
<message>
I can't help with that. Let me transfer you to someone else.
</message>
```

Click **Save** after updating the schema, instructions, and examples.

---

### Step 21: Add Retrieve Tool to AI Agent

The RETRIEVE tool is NOT deployed via CloudFormation. It must be added manually.

1. In the Connect Admin console, go to **AI agent designer** → **AI agents**
2. Click on `anycompany-ivr-agent` → **Edit in Agent Builder**
3. In the **Tools** section, click **Add tool**
4. For **Namespace**, select **Amazon Connect**
5. For **Tool**, select **Retrieve**
6. For **Assistant Association**, select your assistant association from the dropdown

**Tool name:** `Retrieve`

**Instructions:**

```
Search the knowledge base using semantic search to find client-specific information about parking violations, tolling, payments, disputes, policies, and procedures.

Rules:
1. ALWAYS filter by clientId - never return information from other clients
2. Use multiple searches if the first query doesn't fully answer the question
3. Only provide information that is explicitly found in the knowledge base
4. If information is not found, say "I don't have that specific information" and offer agent transfer
5. Never make assumptions about client policies or procedures

Use this tool to answer questions about: payment methods, fees, dispute eligibility, business hours, late penalties, payment plans, and account policies.
```

**Add Examples:**

Good example — Detailed policy response:
```
<message>
Metro Parking Authority accepts several payment methods. You can pay with credit cards including Visa, MasterCard, American Express, and Discover. We also accept debit cards and electronic checks. Please note there is a small convenience fee - 2.5% for card payments with a minimum of $1.50, or a flat $1.00 fee for electronic checks. Would you like to make a payment now?.
</message>
```

Good example query: `"What happens if I don't pay my ticket on time?"`

Bad example query: `"don't pay ticket"`

Click **Add** to add the tool, then **Publish** to update your agent.

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
- [Troubleshooting Guide](troubleshooting.md) — general troubleshooting steps


