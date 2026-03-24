# Lambda Handler Mapping Reference

This document maps each Lambda function to its correct handler configuration.

| Lambda Function | Handler | Source File | Runtime |
|----------------|---------|-------------|---------|
| get-call-attributes | `index.lambda_handler` | `index.py` | python3.12 |
| connect-assistant-update-session | `index.handler` | `index.js` | nodejs20.x |
| lookup-by-plate | `index.lambda_handler` | `index.py` | python3.12 |
| lookup-by-citation | `index.lambda_handler` | `index.py` | python3.12 |
| lookup-by-account | `index.lambda_handler` | `index.py` | python3.12 |
| get-balance | `index.lambda_handler` | `index.py` | python3.12 |
| get-violation-details | `index.lambda_handler` | `index.py` | python3.12 |
| submit-dispute | `index.lambda_handler` | `index.py` | python3.12 |
| check-dispute-status | `index.lambda_handler` | `index.py` | python3.12 |
| qinconnect-dialog-hook | `lambda_function.lambda_handler` | `lambda_function.py` | python3.12 |
| build-payment-cart | `build_payment_cart.lambda_handler` | `build_payment_cart.py` | python3.12 |
| initiate-payment | `initiate_payment.lambda_handler` | `initiate_payment.py` | python3.12 |
| seed-payment-session | `seed_session.lambda_handler` | `seed_session.py` | python3.12 |
| payment-processing | `index.lambda_handler` | `index.py` | python3.12 |
| update-violation-balance | `index.lambda_handler` | `index.py` | python3.12 |
| save-and-restore-session | `index.lambda_handler` | `index.py` | python3.12 |

---

## Important Notes

- Handler format: `<module_name>.` where module name = filename without `.py`/`.js`
- CloudFormation `ZipFile` inline code creates the file using the module name from the handler
- Only `connect-assistant-update-session` uses Node.js; all others use Python 3.12