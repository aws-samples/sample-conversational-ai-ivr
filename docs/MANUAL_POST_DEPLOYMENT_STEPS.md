# AnyCompany IVR — Manual Post-Deployment Steps
# Document Version: 1.0
# Date: 2026-03-23
# 
# These steps CANNOT be fully automated in CloudFormation due to
# dependency ordering, runtime-generated values, or manual configuration
# requirements. They must be executed after CFN stack deployment.

## ========================================================
## STEP 1: Update AI Prompt Model ID
## ========================================================
## Template: Connect Config (Q in Connect)
## Resource: OrchestrationPrompt
## 
## CFN deploys with: us.amazon.nova-lite-v1:0
## Actual required:  us.anthropic.claude-haiku-4-5-20251001-v1:0
##
## Action: Update via Console or CLI after deployment
## 
## aws wisdom update-ai-prompt \
##     --assistant-id <assistant_id> \
##     --ai-prompt-id  \
##     --model-id "us.anthropic.claude-haiku-4-5-20251001-v1:0" \
##     --region us-east-1


## ========================================================
## STEP 2: Update AI Prompt Content (Add Payment Tools)
## ========================================================
## Template: Connect Config (Q in Connect)
## Resource: OrchestrationPrompt
##
## The orchestration prompt needs to include instructions for:
##   - buildPaymentCart tool usage
##   - initiatePayment tool usage  
##   - Payment flow sequence (buildCart → initiatePayment → Escalate PAYMENT_TRANSFER)
##
## Action: Update prompt text via Console or CLI
##   - Add buildPaymentCart and initiatePayment to  section
##   - Add payment flow examples to  section
##   - Add payment-specific instructions to  section


## ========================================================
## STEP 3: Update Escalate Tool Input Schema on AI Agent
## ========================================================
## Template: AI Agent
## Resource: OrchestrationAIAgent → Escalate tool
##
## Current schema has only 'reason' field.
## Must be updated to include:
##   - escalationReason (string) — Category code: PAYMENT_TRANSFER, CUSTOMER_REQUEST, etc.
##   - customerIntent (string) — What the customer wants to accomplish
##   - escalationSummary (string) — Detailed context for receiving agent
##   - sentiment (string) — Customer emotional state
##
## These fields are read by:
##   - QinConnectDialogHook Lambda (detects PAYMENT_TRANSFER)
##   - Connect flow (routes based on Tool attribute)
##   - Agent screen pop (displays escalation context)
##
## Action: Update via Console or CLI after deployment


## ========================================================
## STEP 4: Add All Tool Configurations to AI Agent
## ========================================================
## Template: AI Agent
## Resource: OrchestrationAIAgent → ToolConfigurations
##
## Verify all tools are registered with correct:
##   - ToolName (with correct prefix/separator pattern)
##   - ToolId (gateway_{gatewayId}__{targetName}___{toolName})
##   - Instructions
##
## Tools to verify:
##   [ ] lookupByPlate
##   [ ] lookupByCitation
##   [ ] lookupByAccount
##   [ ] getBalance
##   [ ] getViolationDetails
##   [ ] submitDispute
##   [ ] checkDisputeStatus
##   [ ] buildPaymentCart
##   [ ] initiatePayment
##   [ ] Escalate (RETURN_TO_CONTROL)
##   [ ] Complete (RETURN_TO_CONTROL)
##   [ ] RETRIEVE (Knowledge Base — may be auto-configured)
##
## Action: Verify via Console; add any missing tools manually


## ========================================================
## STEP 5: Update PaymentBotId and PaymentBotAliasId
## ========================================================
## Template: Payment Handoff
## Resource: SeedPaymentSession Lambda
##
## PaymentCollectionBot is created AFTER this stack deploys.
## The env vars PAYMENT_BOT_ID and PAYMENT_BOT_ALIAS_ID default
## to "PENDING" and must be updated once the bot exists.
##
## aws lambda update-function-configuration \
##     --function-name ivr-dev-SeedPaymentSession \
##     --environment '{
##         "Variables": {
##             "KMS_KEY_ARN": "",
##             "ENVIRONMENT": "dev",
##             "SESSION_TABLE_NAME": "",
##             "PAYMENT_BOT_ID": "",
##             "PAYMENT_BOT_ALIAS_ID": ""
##         }
##     }' \
##     --region us-east-1
##
## Also update the IAM policy with actual bot ARN:
## aws iam put-role-policy \
##     --role-name ivr-dev-SeedPaymentSessionRole \
##     --policy-name LexPaymentBotAccess \
##     --policy-document '{...with actual bot ARN...}'


## ========================================================
## STEP 6: Deploy Actual Lambda Code
## ========================================================
## All 16 Lambda functions are created with stub/placeholder code.
## Actual code must be deployed after stack creation.
##
## Handler-to-filename mapping (CRITICAL — must match):
##
##   | Lambda                              | Handler                           | Source File              |
##   |-------------------------------------|-----------------------------------|--------------------------|
##   | anycompany-ivr-dev-getCallAttributes| index.lambda_handler              | index.py                 |
##   | ConnectAssistantUpdateSessionDataNew| index.handler                     | index.js                 |
##   | ivr-dev-SaveAndRestoreSession       | index.lambda_handler              | index.py                 |
##   | ivr-dev-SeedPaymentSession          | seed_session.lambda_handler       | seed_session.py          |
##   | ivr-dev-UpdateViolationBalance      | index.lambda_handler              | index.py                 |
##   | anycompany-ivr-dev-QinConnectDialogHook | lambda_function.lambda_handler | lambda_function.py      |
##   | ivr-dev-PaymentProcessing           | index.lambda_handler              | index.py                 |
##   | anycompany-ivr-build-payment-cart   | build_payment_cart.lambda_handler  | build_payment_cart.py    |
##   | anycompany-ivr-initiate-payment     | initiate_payment.lambda_handler   | initiate_payment.py      |
##   | All 7 tool lambdas                  | index.lambda_handler              | index.py                 |
##
## Deploy script:
##   for each lambda:
##     cd 
##     zip -r code.zip  [additional files]
##     aws lambda update-function-code \
##         --function-name  \
##         --zip-file fileb://code.zip \
##         --region us-east-1


## ========================================================
## STEP 7: Associate Bots with Connect Instance
## ========================================================
## ParkAndTollBot and PaymentCollectionBot must be associated
## with the Connect instance after both are created.
##
## aws connect associate-bot \
##     --instance-id  \
##     --lex-v2-bot AliasArn=arn:aws:lex:us-east-1::bot-alias// \
##     --region us-east-1


## ========================================================
## STEP 8: Associate Lambdas with Connect Instance
## ========================================================
## 5 Lambdas must be associated with Connect (if not done by CFN):
##   - ConnectAssistantUpdateSessionDataNew (done by its CFN via IntegrationAssociation)
##   - anycompany-ivr-dev-getCallAttributes
##   - ivr-dev-SaveAndRestoreSession
##   - ivr-dev-SeedPaymentSession
##   - ivr-dev-UpdateViolationBalance
##
## aws connect associate-lambda-function \
##     --instance-id  \
##     --function-arn  \
##     --region us-east-1


## ========================================================
## STEP 9: Configure ParkAndTollBot
## ========================================================
## After bot creation:
##   a) Enable FulfillmentCodeHook on AmazonQInConnect intent
##   b) Configure bot alias locale settings with QinConnectDialogHook Lambda ARN
##   c) Add Lambda resource policy for lexv2.amazonaws.com
##   d) Build locale, create version, update alias to new version
##   e) Use Service-Linked Role: AWSServiceRoleForLexV2Bots_AmazonConnect_
##   f) Tag: AmazonConnectEnabled=True


## ========================================================
## STEP 10: Configure PaymentCollectionBot
## ========================================================
## After bot creation:
##   a) Configure bot alias locale settings with PaymentProcessing Lambda ARN
##   b) Add Lambda resource policy for lexv2.amazonaws.com
##   c) Build locale, create version, update alias


## ========================================================
## STEP 11: Import/Create Contact Flow
## ========================================================
## The Main Flow must be created/imported with correct:
##   - Lambda ARNs (all 5 pointing to new account)
##   - ParkAndTollBot alias ARN (new account)
##   - PaymentCollectionBot alias ARN (new account)
##   - Flow module references (Basic setting configurations)
##   - Queue references (BasicQueue)
##   - Agent Screen Pop flow reference
##   - TTS voice settings
##   - Speech timeout attributes


## ========================================================
## STEP 12: Associate Q in Connect with Connect Instance
## ========================================================
## The Q in Connect assistant must be integrated with
## the Connect instance. This is typically done via
## Connect Console > Amazon Q > Enable.


## ========================================================
## STEP 13: Upload Knowledge Base Content
## ========================================================
## Upload client-specific KB documents to:
##   s3:////
##
## Then sync the knowledge base:
## aws wisdom start-content-upload or via Console


## ========================================================
## STEP 14: Seed DynamoDB Test Data
## ========================================================
## Populate test data in:
##   - anycompany-ivr-client-config-dev (client configurations)
##   - anycompany-ivr-customers-dev (customer records)
##   - anycompany-ivr-violations-dev (violation records)
##
## Use existing seed scripts:
##   python3 seed_client_config.py
##   python3 seed_test_data.py


## ========================================================
## STEP 15: Claim Phone Number
## ========================================================
## Claim a phone number in Connect and associate it
## with the Main Flow.
## Action: Via Connect Console > Phone numbers


## ========================================================
## STEP 16: End-to-End Test
## ========================================================
## Test the complete flow:
##   [ ] Call → AI greets correctly
##   [ ] Provide plate → AI looks up account
##   [ ] Ask about violations → AI retrieves details
##   [ ] Request payment → AI builds cart → initiatePayment
##   [ ] Fulfillment Lambda detects PAYMENT_TRANSFER
##   [ ] Route to PaymentCollectionBot
##   [ ] Collect card details → process payment
##   [ ] Resume AI conversation
##   [ ] Ask policy question → RETRIEVE from KB
##   [ ] Request agent → Escalate to queue