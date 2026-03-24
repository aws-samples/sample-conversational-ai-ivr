# Troubleshooting Guide

## Common Issues

### Call goes directly to "Thank you for calling. Goodbye"

**Cause**: FulfillmentCodeHook enabled on ParkAndTollBot but bot alias has no Lambda configured.

**Fix**: Configure `botAliasLocaleSettings` with the QinConnectDialogHook Lambda ARN.

---

### Fulfillment Lambda fires but payment bot not invoked

**Cause**: `x-amz-lex:q-in-connect-response` returns `"..."` instead of full text.

**Fix**: Use session attribute fallback detection (`Tool=Escalate` + `escalationReason=PAYMENT_TRANSFER`).

---

### DynamoDB AccessDeniedException in fulfillment Lambda

**Cause**: Lambda role missing `dynamodb:Query` and `dynamodb:Scan` permissions.

**Fix**: Add inline policy for session table access.

---

### SeedPaymentSession Lex PutSession AccessDeniedException

**Cause**: Lambda role missing `lex:PutSession` for PaymentCollectionBot.

**Fix**: Add `LexPaymentBotAccess` inline policy.

---

### Lex can't invoke fulfillment Lambda

**Cause**: Missing Lambda resource-based policy for `lexv2.amazonaws.com`.

**Fix**: Add `lambda:InvokeFunction` permission for Lex principal.

---

## Key Rule: Lex V2 Fulfillment Requires 3 Things

1. `fulfillmentCodeHook.enabled=true` on the intent
2. `botAliasLocaleSettings` with Lambda ARN on the alias
3. Resource-based policy on the Lambda for `lexv2.amazonaws.com`

**Missing any one of these causes silent failure** — the call drops or goes to goodbye.