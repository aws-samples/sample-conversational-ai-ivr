# Changelog

All notable changes to the ConversationalIVR project.

## [1.0.0] - 2026-03-24

### Initial Release

- AI-powered IVR conversation using Nova Sonic via Amazon Q in Connect
- 7 AI agent tools (customer lookup, balance, violations, disputes)
- Payment collection flow with PCI-compliant card handling
- 16 Lambda functions (Python 3.12 + Node.js 20.x)
- 13+ CloudFormation templates (standalone + nested)
- Automated Lex bot creation scripts (ParkAndTollBot, PaymentCollectionBot)
- Amazon Connect contact flow with payment routing
- Bedrock AgentCore Gateway integration
- REST API Gateway with OpenAPI specification
- DynamoDB tables for customers, violations, disputes, sessions
- Comprehensive deployment and troubleshooting documentation

### Known Behaviors

- `x-amz-lex:q-in-connect-response` may return `"..."` instead of full text in some environments. Workaround: session attribute-based fallback detection in fulfillment Lambda.