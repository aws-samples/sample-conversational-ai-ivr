# Architecture Overview

## Components

### Amazon Connect
- IVR entry point for inbound calls
- Contact flows orchestrate AI conversation and payment collection
- Session attributes pass context between components

### Amazon Lex V2

**ParkAndTollBot** — Primary conversational bot
- `AmazonQInConnectIntent` with fulfillment code hook enabled
- Fulfillment Lambda detects payment routing signals
- Post-fulfillment returns `((x-amz-lex:q-in-connect-response))`

**PaymentCollectionBot** — PCI card collection
- Slots: cardNumber (obfuscated), expirationDate (obfuscated), cvv (obfuscated), billingZip
- Conversation logs disabled for PCI compliance
- Intents: CollectPayment, CancelPayment, FallbackIntent

### Amazon Q in Connect (Nova Sonic)
- AI conversational intelligence via system prompt
- Invokes tools through Bedrock AgentCore Gateway
- Supports RETRIEVE (knowledge base) and ESCALATE (transfer) actions

### Bedrock AgentCore Gateway
- Routes tool calls from Q in Connect to API Gateway
- API key authentication
- OpenAPI spec defines all available tools

### API Gateway
- REST API with 9 POST endpoints
- API key required for all requests
- Each endpoint backed by a dedicated Lambda

---

## DynamoDB Tables

| Table | PK | Purpose |
|-------|-----|---------|
| customers | PK + SK | Customer records (GSIs: plate, account) |
| violations | PK + SK | Violation records (GSIs: citation, customer) |
| disputes | PK + SK | Dispute records (GSIs: violation, reference) |
| client-config | PK | Phone number mapping |
| session-context | contactId | IVR session state |

---

## Payment Flow Sequence

1. AI determines payment is needed
2. AI calls `initiatePayment` tool — sets session attributes
3. AI calls `Escalate(PAYMENT_TRANSFER)` — signals handoff
4. Fulfillment Lambda detects payment signal (text or session attrs)
5. Returns `dialogAction` to Connect flow with routing signal
6. Connect invokes `SeedPaymentSession` — primes PaymentCollectionBot
7. Connect routes to PaymentCollectionBot for card collection
8. `PaymentProcessing` Lambda processes the payment
9. `SaveAndRestoreSession` Lambda restores AI context
10. Connect returns caller to ParkAndTollBot for continued conversation