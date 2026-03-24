# Deployment Guide

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Python 3.12+, Node.js 20.x+
- Amazon Connect instance created
- Bedrock model access enabled (Nova Sonic)

---

## Step 1: Configure Environment

```bash
cp .env.example .env
# Edit .env with your AWS account details
```

---

## Step 2: Deploy CloudFormation Stacks

Deploy in order using the master script:

```bash
./scripts/deploy-all.sh
```

Or deploy individually:

```bash
# 1. DynamoDB Tables
aws cloudformation deploy --template-file cfn/standalone/01a-client-config-table.yaml \
    --stack-name anycompany-ivr-client-config-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/01b-dynamodb-tables.yaml \
    --stack-name anycompany-ivr-tables-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/01c-session-table.yaml \
    --stack-name anycompany-ivr-session-dev --capabilities CAPABILITY_IAM

# 2. Lambda Functions
aws cloudformation deploy --template-file cfn/standalone/02a-tool-lambdas.yaml \
    --stack-name anycompany-ivr-tools-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/02b-getCallAttributes.yaml \
    --stack-name anycompany-ivr-callattr-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/02c-ConnectAssistantUpdateSessionData.yaml \
    --stack-name anycompany-ivr-sessionupdate-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/02d-payments-lambdas.yaml \
    --stack-name anycompany-ivr-paytools-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/02e-payment-handoff-resources.yaml \
    --stack-name anycompany-ivr-payhandoff-dev --capabilities CAPABILITY_IAM

aws cloudformation deploy --template-file cfn/standalone/02f-fulfillment-hook.yaml \
    --stack-name anycompany-ivr-fulfillment-dev --capabilities CAPABILITY_IAM

# 3. API Gateway
aws cloudformation deploy --template-file cfn/standalone/03-api-gateway.yaml \
    --stack-name anycompany-ivr-api-dev --capabilities CAPABILITY_IAM
```

---

## Step 3: Create Lex Bots

```bash
./scripts/create-park-and-toll-bot.sh
./scripts/create-payment-bot.sh
```

---

## Step 4: Post-Deployment Configuration

See [MANUAL_POST_DEPLOYMENT_STEPS.md](MANUAL_POST_DEPLOYMENT_STEPS.md) for the complete 16-step checklist.

---

## Step 5: Seed Test Data

```bash
python scripts/utilities/seed_test_data.py
python scripts/utilities/seed_client_config.py
```

---

## Step 6: End-to-End Test

Call the phone number associated with your Connect instance and test:

- License plate lookup
- Citation lookup
- Balance inquiry
- Payment flow
- Dispute submission