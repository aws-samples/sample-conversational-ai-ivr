# Troubleshooting

## Call goes to "Goodbye" immediately
**Cause**: Bot alias missing Lambda ARN in locale settings.
**Fix**: Configure `botAliasLocaleSettings` with QinConnectDialogHook ARN.

## Fulfillment fires but no payment routing
**Cause**: `x-amz-lex:q-in-connect-response` returns `"..."` instead of full text.
**Fix**: Session attribute fallback (`Tool=Escalate` + `escalationReason=PAYMENT_TRANSFER`).

## DynamoDB AccessDeniedException
**Cause**: Lambda role missing DynamoDB permissions.
**Fix**: Add inline policy for table access.

## Lex PutSession AccessDeniedException
**Cause**: Lambda role missing `lex:PutSession` for PaymentCollectionBot.
**Fix**: Add LexPaymentBotAccess inline policy.

## Lex can't invoke fulfillment Lambda
**Cause**: Missing Lambda resource-based policy for `lexv2.amazonaws.com`.
**Fix**: Add `lambda:InvokeFunction` permission for Lex principal.

## Lex V2 Fulfillment Requires 3 Things
1. `fulfillmentCodeHook.enabled=true` on intent
2. `botAliasLocaleSettings` with Lambda ARN on alias
3. Resource policy on Lambda for `lexv2.amazonaws.com`

Missing any one causes silent failure.
