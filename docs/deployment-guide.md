# Deployment Guide

## Prerequisites
- AWS CLI v2 configured
- Python 3.12+, Node.js 20.x+
- Amazon Connect instance created
- Bedrock model access (Nova Sonic)

## Step 1: Configure Environment
```bash
cp .env.example .env
# Edit .env with your AWS account details

Step 2: Deploy CloudFormation Stacks (in order)

./scripts/deploy-all.sh

Or individually:

# 1. DynamoDB Tables
aws cloudformation deploy --template-file cfn/standalone/01a-client-config-table.yaml ...
aws cloudformation deploy --template-file cfn/standalone/01b-dynamodb-tables.yaml ...
aws cloudformation deploy --template-file cfn/standalone/01c-session-table.yaml ...

# 2. Lambda Functions
aws cloudformation deploy --template-file cfn/standalone/02a-tool-lambdas.yaml ...
aws cloudformation deploy --template-file cfn/standalone/02b-getCallAttributes.yaml ...
aws cloudformation deploy --template-file cfn/standalone/02c-ConnectAssistantUpdateSessionData.yaml ...
aws cloudformation deploy --template-file cfn/standalone/02d-payments-lambdas.yaml ...
aws cloudformation deploy --template-file cfn/standalone/02e-payment-handoff-resources.yaml ...
aws cloudformation deploy --template-file cfn/standalone/02f-fulfillment-hook.yaml ...

# 3. API Gateway
aws cloudformation deploy --template-file cfn/standalone/03-api-gateway.yaml ...

Step 3: Create Lex Bots

./scripts/create-park-and-toll-bot.sh
./scripts/create-payment-bot.sh

Step 4: Post-Deployment

See MANUAL_POST_DEPLOYMENT_STEPS.md for the 16-step checklist.
Step 5: Seed Test Data

python scripts/utilities/seed_test_data.py
python scripts/utilities/seed_client_config.py

EOF echo " OK docs/deployment-guide.md"
--- scripts/utilities/sanitize-check.sh ---

cat > "${REPO_ROOT}/scripts/utilities/sanitize-check.sh" << 'SCANEOF' #!/bin/bash REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)" ERRORS=0 SAFE="123456789012|111111111111|PLACEHOLDER|REPLACE_WITH|xxxxxxxx|XXXXXXXXXX|your-|000000000000|example"

echo "Scanning for secrets in ${REPO_ROOT}..."

echo "--- [1/5] AWS Account IDs ---" F=$(grep -rn '[0-9]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include=".json" --include=".yaml" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}|sanitize-check" | grep -E '[0-9]{12}' || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [2/5] Hardcoded ARNs ---" F=$(grep -rn 'arn:aws:' "${REPO_ROOT}" --include=".py" --include=".js" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}|# ARN" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [3/5] .env files ---" F=$(find "${REPO_ROOT}" -name ".env" -not -name ".env.example" -not -path "/.git/" 2>/dev/null || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [4/5] UUIDs in source ---" F=$(grep -rn '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "--- [5/5] S3 buckets with account IDs ---" F=$(grep -rn 's3://.[0-9]{12}' "${REPO_ROOT}" --include=".py" --include=".js" --include=".yaml" --include="*.sh" --exclude-dir=.git 2>/dev/null | grep -Ev "${SAFE}" || true) if [ -n "$F" ]; then echo " WARNING:"; echo "$F"; ERRORS=$((ERRORS+1)); else echo " OK"; fi

echo "" if [ $ERRORS -gt 0 ]; then echo "FAILED: ${ERRORS} issue(s)"; exit 1; else echo "PASSED: No secrets"; fi SCANEOF chmod +x "${REPO_ROOT}/scripts/utilities/sanitize-check.sh" echo " OK scripts/utilities/sanitize-check.sh"
--- Placeholder READMEs ---

cat > "${REPO_ROOT}/knowledge-base/README.md" << 'EOF'
Knowledge Base Content

Place documents here for the Amazon Q in Connect RETRIEVE tool. Upload to the S3 bucket configured as KB_BUCKET in your .env file.
Expected Content

    Parking violation policies and procedures
    Toll violation policies and procedures
    Payment and dispute resolution guidelines
    FAQ documents EOF echo " OK knowledge-base/README.md"

cat > "${REPO_ROOT}/test-data/README.md" << 'EOF'
Test Data

Seed DynamoDB tables:

python scripts/utilities/seed_test_data.py
python scripts/utilities/seed_client_config.py

EOF echo " OK test-data/README.md"

cat > "${REPO_ROOT}/tests/README.md" << 'EOF'
Tests

python -m pytest tests/unit/ -v
python -m pytest tests/integration/ -v

EOF echo " OK tests/README.md"

cat > "${REPO_ROOT}/connect-flows/README.md" << 'EOF'
Amazon Connect Contact Flows
main-ivr-flow.json

After importing into Amazon Connect, update all resource ARNs:

    Lex Bot ARNs (ParkAndTollBot, PaymentCollectionBot)
    Lambda function ARNs (all 16)
    Q in Connect Assistant ARN
    Queue ARNs (if using agent escalation)

See ../docs/MANUAL_POST_DEPLOYMENT_STEPS.md Step 11. EOF echo " OK connect-flows/README.md"

cat > "${REPO_ROOT}/iam-reference/README.md" << 'EOF'
IAM Reference Policies

Snapshots of IAM policies from the live environment, for reference. CloudFormation templates define their own IAM roles and policies.
Structure

iam-reference//
    trust-policy.json          # Lambda assume role
    managed-policies.json      # Attached AWS managed policies
    inline-*.json             # Custom inline policies

EOF echo " OK iam-reference/README.md"

echo "" echo " All missing files created"
-------------------------------------------------------------------
PART B: Final file count
-------------------------------------------------------------------

echo "" echo ">>> PART B: Final verification" echo ""

TOTAL=$(find "${REPO_ROOT}" -type f | wc -l | tr -d ' ') MD=$(find "${REPO_ROOT}" -name ".md" | wc -l | tr -d ' ') echo "Total files: ${TOTAL}" echo "Markdown: ${MD}" echo "" find "${REPO_ROOT}" -name ".md" | sed "s|${REPO_ROOT}/||" | sort
-------------------------------------------------------------------
PART C: Initialize Git
-------------------------------------------------------------------

echo "" echo ">>> PART C: Initialize Git repository" echo ""

cd "${REPO_ROOT}"
Remove any existing .git (shouldn't be one)

rm -rf .git

git init echo " OK git init"

git add -A echo " OK git add -A"
Show what will be committed

echo "" echo " Files staged for commit:" git status --short | wc -l | tr -d ' ' echo " files total" echo ""
Check for any large files

echo " Checking for files > 1MB..." find . -type f -size +1M -not -path "./.git/*" | head -5 || echo " None found" echo ""

git commit -m "Initial commit: ConversationalIVR - AI-powered IVR system

    16 Lambda functions (Python 3.12 + Node.js 20.x)
    20 CloudFormation templates (standalone + nested)
    Amazon Connect contact flow
    OpenAPI spec for API Gateway
    Lex bot creation scripts (ParkAndTollBot, PaymentCollectionBot)
    AI agent system prompt
    IAM policy reference
    Deployment, architecture, and troubleshooting docs
    All sensitive data sanitized (account IDs, ARNs, API keys replaced with placeholders)"

echo "" echo " OK initial commit"
-------------------------------------------------------------------
PART D: GitHub setup instructions
-------------------------------------------------------------------

echo "" echo "============================================" echo "GIT REPO READY" echo "============================================" echo "" echo "Local repo: ${REPO_ROOT}" echo "" git log --oneline -1 echo "" git shortlog -sn echo "" echo "============================================" echo "TO PUSH TO GITHUB:" echo "============================================" echo "" echo "1. Create a new repo on GitHub:" echo " https://github.com/new" echo " Name: ConversationalIVR" echo " Visibility: Private (recommended)" echo " Do NOT initialize with README/gitignore/license" echo "" echo "2. Add remote and push:" echo " cd ${REPO_ROOT}" echo " git remote add origin https://github.com/YOUR_USERNAME/ConversationalIVR.git" echo " git branch -M main" echo " git push -u origin main" echo "" echo " Or with SSH:" echo " git remote add origin git@github.com:YOUR_USERNAME/ConversationalIVR.git" echo " git branch -M main" echo " git push -u origin main" echo "" echo "============================================"

