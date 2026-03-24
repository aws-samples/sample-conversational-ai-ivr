# Amazon Connect Contact Flows

## main-ivr-flow.json

Primary IVR contact flow. Import into your Amazon Connect instance.

### After Importing, Update These Resource ARNs:

- Lex Bot ARNs (ParkAndTollBot, PaymentCollectionBot)
- Lambda function ARNs (all 16 functions)
- Q in Connect Assistant ARN
- Queue ARNs (if using agent escalation)

See [../docs/MANUAL_POST_DEPLOYMENT_STEPS.md](../docs/MANUAL_POST_DEPLOYMENT_STEPS.md) Step 11.