# ConversationalIVR — AI-Powered Parking & Toll Violation IVR

An AI-powered Interactive Voice Response (IVR) system built on AWS using Amazon Connect, Amazon Lex V2, Amazon Q in Connect with Nova Sonic, and Bedrock AgentCore Gateway.

Callers can look up violations by license plate, citation number, or account; check balances; get violation details; submit disputes; and make payments — all through natural conversation.

## Architecture

Customer (Phone) | v Amazon Connect (IVR Flow) | v Amazon Lex V2 (ParkAndTollBot) <--> Amazon Q in Connect (Nova Sonic LLM) | | v v Fulfillment Lambda Bedrock AgentCore Gateway | | v v Connect Flow Routing Tool Lambdas (via API Gateway) | - lookupByPlate / Citation / Account v - getBalance, getViolationDetails Payment Flow (if needed) - submitDispute, checkDisputeStatus | - buildPaymentCart, initiatePayment v - ESCALATE / RETRIEVE Amazon Lex V2 (PaymentCollectionBot) | v Resume AI Conversation

## Quick Start

```bash
cp .env.example .env            # Configure your environment
./scripts/deploy-all.sh          # Deploy CloudFormation stacks
./scripts/create-park-and-toll-bot.sh
./scripts/create-payment-bot.sh

See docs/MANUAL_POST_DEPLOYMENT_STEPS.md for full setup.
Lambda Functions (16)
#	Function	Category	Description
1-7	lookup-by-plate/citation/account, get-balance, get-violation-details, submit-dispute, check-dispute-status	Tool	AI agent tools
8	qinconnect-dialog-hook	Fulfillment	Payment routing detection
9-10	build-payment-cart, initiate-payment	Payment Tool	Payment preparation
11-14	seed-payment-session, payment-processing, update-violation-balance, save-and-restore-session	Payment	Payment execution
15-16	get-call-attributes, connect-assistant-update-session	Connect	Connect integration
Security

No AWS account IDs, ARNs, or credentials in this repo. Configure via .env file. Run ./scripts/utilities/sanitize-check.sh before committing.
License

MIT READMEEOF

echo " Done"
-------------------------------------------------------------------
STEP 15: Create sanitize-check script
-------------------------------------------------------------------

echo "" echo ">>> STEP 15: Create secret scanner"

cat > "${REPO_ROOT}/scripts/utilities/sanitize-check.sh" << 'SCANEOF' #!/bin/bash REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)" ERRORS=0 SAFE="123456789012|111111111111|PLACEHOLDER|REPLACE_WITH|xxxxxxxx|XXXXXXXXXX|your-|000000000000|example"

echo "Scanning for secrets in ${REPO_ROOT}..."

echo "--- [1/5] AWS Account IDs ---" F=$(grep -rn '[0-9]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include=".json" --include=".yaml" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}|sanitize-check" | grep -E '[0-9]{12}' || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [2/5] Hardcoded ARNs ---" F=$(grep -rn 'arn:aws:' "${REPO_ROOT}" --include=".py" --include=".js" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}|# ARN" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [3/5] .env files ---" F=$(find "${REPO_ROOT}" -name ".env" -not -name ".env.example" -not -path "/.git/" 2>/dev/null || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [4/5] UUIDs in source ---" F=$(grep -rn '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [5/5] S3 buckets with account IDs ---" F=$(grep -rn 's3://.[0-9]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include=".yaml" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "" if [ $ERRORS -gt 0 ]; then echo "FAILED: ${ERRORS} issue(s)"; exit 1; else echo "PASSED: No secrets"; fi SCANEOF

chmod +x "${REPO_ROOT}/scripts/utilities/sanitize-check.sh" echo " Done"
-------------------------------------------------------------------
STEP 16: Create docs
-------------------------------------------------------------------

echo "" echo ">>> STEP 16: Create documentation"

cat > "${REPO_ROOT}/docs/lambda-handlers.md" << 'EOF'
Lambda Handler Mapping Reference
Lambda Function	Handler	Source File	Runtime
get-call-attributes	index.lambda_handler	index.py	python3.12
connect-assistant-update-session	index.handler	index.js	nodejs20.x
lookup-by-plate	index.lambda_handler	index.py	python3.12
lookup-by-citation	index.lambda_handler	index.py	python3.12
lookup-by-account	index.lambda_handler	index.py	python3.12
get-balance	index.lambda_handler	index.py	python3.12
get-violation-details	index.lambda_handler	index.py	python3.12
submit-dispute	index.lambda_handler	index.py	python3.12
check-dispute-status	index.lambda_handler	index.py	python3.12
qinconnect-dialog-hook	lambda_function.lambda_handler	lambda_function.py	python3.12
build-payment-cart	build_payment_cart.lambda_handler	build_payment_cart.py	python3.12
initiate-payment	initiate_payment.lambda_handler	initiate_payment.py	python3.12
seed-payment-session	seed_session.lambda_handler	seed_session.py	python3.12
payment-processing	index.lambda_handler	index.py	python3.12
update-violation-balance	index.lambda_handler	index.py	python3.12
save-and-restore-session	index.lambda_handler	index.py	python3.12
EOF			

cat > "${REPO_ROOT}/docs/architecture.md" << 'EOF'
Architecture Overview
Payment Flow Sequence

    AI determines payment needed
    AI calls initiatePayment tool -> sets session attributes
    AI calls Escalate(PAYMENT_TRANSFER) -> signals handoff
    Fulfillment Lambda detects signal (text or session attrs)
    Returns dialogAction to Connect flow
    Connect invokes SeedPaymentSession -> primes PaymentCollectionBot
    Connect routes to PaymentCollectionBot for card collection
    PaymentProcessing Lambda processes payment
    SaveAndRestoreSession restores AI context
    Connect returns caller to ParkAndTollBot

DynamoDB Tables
Table	PK	Purpose
customers	PK + SK	Customer records (GSIs: plate, account)
violations	PK + SK	Violation records (GSIs: citation, customer)
disputes	PK + SK	Dispute records (GSIs: violation, reference)
client-config	PK	Phone number mapping
session-context	contactId	IVR session state
EOF		

cat > "${REPO_ROOT}/docs/troubleshooting.md" << 'EOF'
Troubleshooting
Call goes to Goodbye immediately

Cause: Bot alias missing Lambda ARN in locale settings. Fix: Configure botAliasLocaleSettings with QinConnectDialogHook ARN.
Fulfillment fires but no payment routing

Cause: x-amz-lex:q-in-connect-response returns "...". Fix: Session attribute fallback (Tool=Escalate + escalationReason=PAYMENT_TRANSFER).
Lex V2 Fulfillment Requires 3 Things

    fulfillmentCodeHook.enabled=true on intent
    botAliasLocaleSettings with Lambda ARN on alias
    Resource policy on Lambda for lexv2.amazonaws.com EOF

echo " Done - 3 docs"
-------------------------------------------------------------------
STEP 17: Create CHANGELOG + placeholders
-------------------------------------------------------------------

echo "" echo ">>> STEP 17: Create CHANGELOG + placeholders"

cat > "${REPO_ROOT}/CHANGELOG.md" << 'EOF'
Changelog
[1.0.0] - 2026-03-24
Initial Release

    AI-powered IVR with Nova Sonic via Amazon Q in Connect
    16 Lambda functions, 13+ CloudFormation templates
    Payment collection with PCI compliance
    Automated Lex bot creation scripts
    Bedrock AgentCore Gateway integration EOF

cat > "${REPO_ROOT}/knowledge-base/README.md" << 'EOF'
Knowledge Base Content

Place documents here for the Amazon Q in Connect RETRIEVE tool. EOF

cat > "${REPO_ROOT}/test-data/README.md" << 'EOF'
Test Data

Run: python scripts/utilities/seed_test_data.py EOF

cat > "${REPO_ROOT}/tests/README.md" << 'EOF'
Tests

Run: python -m pytest tests/unit/ -v EOF

cat > "${REPO_ROOT}/connect-flows/README.md" << 'EOF'
Amazon Connect Contact Flows

After importing main-ivr-flow.json, update all resource ARNs. EOF

cat > "${REPO_ROOT}/iam-reference/README.md" << 'EOF'
IAM Reference Policies

Snapshots from live env. CFN templates define their own IAM. EOF

echo " Done"
-------------------------------------------------------------------
STEP 18: Set permissions
-------------------------------------------------------------------

echo "" echo ">>> STEP 18: Set file permissions" find "${REPO_ROOT}/scripts" -name "*.sh" -exec chmod +x {} ; echo " Done"
-------------------------------------------------------------------
STEP 19: VERIFY SANITIZATION
-------------------------------------------------------------------

echo "" echo ">>> STEP 19: VERIFY SANITIZATION (17 checks)" echo ""

SCAN_ERRORS=0

check_clean() { local label="$1" local pattern="$2" FOUND=$(grep -rn "${pattern}" "${REPO_ROOT}" 2>/dev/null | grep -v ".git" || true) if [ -n "$FOUND" ]; then echo " FAIL ${label}:" echo "$FOUND" | head -5 SCAN_ERRORS=$((SCAN_ERRORS + 1)) else echo " PASS ${label}" fi }

check_clean "New Account ID" "${ACCT_NEW}" check_clean "Old Account ID" "${ACCT_OLD}" check_clean "Connect Instance (new)" "${CONNECT_INSTANCE_NEW}" check_clean "Connect Instance (old)" "${CONNECT_INSTANCE_OLD}" check_clean "Wisdom Assistant (new)" "${WISDOM_ASSISTANT_NEW}" check_clean "Wisdom Assistant (old)" "${WISDOM_ASSISTANT_OLD}" check_clean "API Gateway ID" "${APIGW_ID}" check_clean "API Key ID" "${APIGW_KEY_ID}" check_clean "ParkAndToll Bot ID" "${PARK_BOT_ID}" check_clean "ParkAndToll Bot Alias" "${PARK_BOT_ALIAS}" check_clean "Payment Bot ID" "${PAY_BOT_ID}" check_clean "Payment Bot Alias" "${PAY_BOT_ALIAS}" check_clean "Payment Bot Old ID" "${PAY_BOT_OLD_ID}" check_clean "Payment Bot Old Alias" "${PAY_BOT_OLD_ALIAS}" check_clean "AgentCore Gateway" "${AGENTCORE_GW}" check_clean "S3 CFN Bucket" "${S3_BUCKET_CFN}" check_clean "S3 KB Bucket" "${S3_BUCKET_KB}"

echo "" if [ $SCAN_ERRORS -gt 0 ]; then echo "WARNING: ${SCAN_ERRORS} SANITIZATION ISSUE(S)" else echo "ALL 17 SANITIZATION CHECKS PASSED" fi
-------------------------------------------------------------------
STEP 20: Final structure + summary
-------------------------------------------------------------------

echo "" echo ">>> STEP 20: Final structure" echo ""

if command -v tree >/dev/null 2>&1; then tree "${REPO_ROOT}" --dirsfirst -L 4 -I ".git" else find "${REPO_ROOT}" -type f | sed "s|${REPO_ROOT}/||" | sort fi

echo "" echo "============================================" echo "BUILD COMPLETE" echo "============================================" TOTAL=$(find "${REPO_ROOT}" -type f | wc -l | tr -d ' ') PY=$(find "${REPO_ROOT}" -name ".py" | wc -l | tr -d ' ') JS=$(find "${REPO_ROOT}" -name ".js" | wc -l | tr -d ' ') YML=$(find "${REPO_ROOT}" -name ".yaml" | wc -l | tr -d ' ') SH=$(find "${REPO_ROOT}" -name ".sh" | wc -l | tr -d ' ') JSN=$(find "${REPO_ROOT}" -name ".json" | wc -l | tr -d ' ') MD=$(find "${REPO_ROOT}" -name ".md" | wc -l | tr -d ' ') echo "Location: ${REPO_ROOT}" echo "Total files: ${TOTAL}" echo " Python: ${PY}" echo " JavaScript: ${JS}" echo " YAML: ${YML}" echo " Shell: ${SH}" echo " JSON: ${JSN}" echo " Markdown: ${MD}" echo "Sanitize issues: ${SCAN_ERRORS}" echo "" echo "Original UNTOUCHED: ${SRC_ROOT}" echo "" echo "NEXT: bash /tmp/git-init-and-push.sh" echo "============================================"

