import json
import os
import logging
import re
import urllib.request
import urllib.parse
import boto3
from datetime import datetime, timezone
from decimal import Decimal

logger = logging.getLogger()
logger.setLevel(os.environ.get('LOG_LEVEL', 'INFO'))

ssm_client = boto3.client('ssm')
dynamodb   = boto3.resource('dynamodb')

VIOLATIONS_TABLE = os.environ.get(
    'VIOLATIONS_TABLE',
    'anycompany-ivr-violations-dev'
)
CUSTOMERS_TABLE = os.environ.get(
    'CUSTOMERS_TABLE',
    'anycompany-ivr-customers-dev'
)

_api_key = None

# ---------------------------------------------------------------------------
# URL validation – remediates Bandit B310 / CWE-22 (SSRF / path traversal)
# ---------------------------------------------------------------------------
ALLOWED_URL_SCHEMES = ('https',)
_ALLOWED_API_HOSTS = None


def _get_allowed_api_hosts():
    """
    Return the set of hostnames that this Lambda is permitted to call.
    Derived from the VIOLATION_API_URL environment variable.
    """
    global _ALLOWED_API_HOSTS
    if _ALLOWED_API_HOSTS is None:
        api_url = os.environ.get('VIOLATION_API_URL', '')
        hosts = set()
        if api_url and api_url != 'MOCK_MODE':
            parsed = urllib.parse.urlparse(api_url)
            if parsed.hostname:
                hosts.add(parsed.hostname.lower())
        _ALLOWED_API_HOSTS = hosts
        logger.debug(f"Allowed API hosts initialised: {_ALLOWED_API_HOSTS}")
    return _ALLOWED_API_HOSTS


def validate_url(url):
    """
    Validate a URL before opening it.

    Ensures:
      1. Scheme is HTTPS only (blocks file://, ftp://, gopher://, etc.)
      2. Host is in the allow-list derived from VIOLATION_API_URL
      3. No embedded credentials (user:pass@host)
      4. No path-traversal sequences (..)

    Raises ValueError on any violation.

    Remediates: Bandit B310, CWE-22
    """
    parsed = urllib.parse.urlparse(url)

    # 1. Enforce HTTPS only
    if parsed.scheme not in ALLOWED_URL_SCHEMES:
        raise ValueError(
            f"Blocked URL scheme '{parsed.scheme}'. "
            f"Allowed: {ALLOWED_URL_SCHEMES}"
        )

    # 2. Enforce allow-listed hosts
    hostname = (parsed.hostname or '').lower()
    allowed = _get_allowed_api_hosts()
    if not allowed:
        raise ValueError(
            "No allowed API hosts configured. "
            "Set VIOLATION_API_URL environment variable."
        )
    if hostname not in allowed:
        raise ValueError(
            f"Host '{hostname}' not in allowed hosts: {allowed}"
        )

    # 3. Reject embedded credentials
    if parsed.username or parsed.password:
        raise ValueError("URL must not contain embedded credentials")

    # 4. Reject path traversal
    if '..' in parsed.path:
        raise ValueError("URL path must not contain '..'")

    return url


def sanitize_path_segment(value):
    """
    Sanitise a value used in a URL path segment.
    Allows only alphanumeric characters, hyphens, and underscores.
    Raises ValueError if the input contains illegal characters.

    Prevents path traversal (e.g. '../../etc/passwd') and injection.
    """
    if not re.match(r'^[a-zA-Z0-9_-]+$', value):
        raise ValueError(
            f"Invalid path segment: '{value}'. "
            f"Only alphanumeric, hyphens, and underscores allowed."
        )
    return value


def get_api_key():
    global _api_key
    if _api_key is None:
        try:
            response = ssm_client.get_parameter(
                Name=os.environ.get(
                    'VIOLATION_API_KEY_PARAM',
                    '/ivr/payment/dev/violation-api-key'
                ),
                WithDecryption=True
            )
            _api_key = response['Parameter']['Value']
        except Exception as e:
            logger.warning(f"Could not load API key: {e}. Using MOCK_MODE")
            _api_key = 'MOCK_MODE'
    return _api_key


def lambda_handler(event, context):
    logger.info("UpdateViolationBalance invoked")
    logger.info(f"Event: {json.dumps(event)}")

    try:
        parameters = event.get('Details', {}).get('Parameters', {})
        payment_status = parameters.get('paymentStatus', '')

        if payment_status != 'success':
            logger.info(f"Payment status is '{payment_status}'. Skipping.")
            return {
                'updateStatus':      'SKIPPED',
                'updatedViolations': '0',
                'failedViolations':  '',
                'updateMessage':     f'Payment not successful ({payment_status}). No violations updated.'
            }

        transaction_id        = parameters.get('transactionId', '')
        payment_amount        = parameters.get('paymentAmount', '0')
        violation_ids_str     = parameters.get('violationIds', '')
        violation_amounts_str = parameters.get('violationAmounts', '')
        payment_type          = parameters.get('paymentType', 'FULL')
        customer_id           = parameters.get('customerId', '')
        client_id             = parameters.get('clientId', '')
        account_number        = parameters.get('accountNumber', '')

        if not transaction_id:
            logger.error("No transactionId provided")
            return {
                'updateStatus': 'FAILED', 'updatedViolations': '0',
                'failedViolations': violation_ids_str,
                'updateMessage': 'No transaction ID'
            }

        if not violation_ids_str:
            logger.warning("No violationIds provided.")
            return {
                'updateStatus': 'FAILED', 'updatedViolations': '0',
                'failedViolations': '',
                'updateMessage': 'No violation IDs provided'
            }

        if not customer_id or not client_id:
            logger.error(f"Missing customerId='{customer_id}' or clientId='{client_id}'")
            return {
                'updateStatus': 'FAILED', 'updatedViolations': '0',
                'failedViolations': violation_ids_str,
                'updateMessage': 'Missing customerId or clientId'
            }

        violation_ids = [v.strip() for v in violation_ids_str.split(',') if v.strip()]
        violation_amounts = [
            a.strip() for a in violation_amounts_str.split(',') if a.strip()
        ] if violation_amounts_str else []

        logger.info(
            f"Processing {len(violation_ids)} violation(s). "
            f"TransactionId={transaction_id}, PaymentType={payment_type}, "
            f"Total={payment_amount}, CustomerId={customer_id}, ClientId={client_id}"
        )

        # ──────────────────────────────────────────────────────────
        # Payment routing logic
        #
        # Determine if this is a partial payment using three layers:
        #   1. Explicit paymentType value (new: PARTIAL, old: PARTIAL_AMOUNT)
        #   2. Compare paymentAmount vs sum of violationAmounts (safety net)
        #   3. Default to full if we can't determine
        #
        # This handles both old enum values (PARTIAL_AMOUNT, FULL_BALANCE,
        # ALL_PAYABLE, SPECIFIC) and new enum values (FULL, PARTIAL).
        # ──────────────────────────────────────────────────────────
        total_violation_balance = sum(
            Decimal(str(a)) for a in violation_amounts
        ) if violation_amounts else Decimal('0')

        payment_amount_dec = Decimal(str(payment_amount))

        is_partial = False
        payment_type_upper = payment_type.upper().strip()

        if payment_type_upper in ('PARTIAL', 'PARTIAL_AMOUNT'):
            # Layer 1: Explicitly marked as partial by either new or old schema
            is_partial = True
            logger.info(
                f"Partial payment detected via paymentType='{payment_type}'"
            )
        elif payment_type_upper in ('FULL', 'FULL_BALANCE', 'ALL_PAYABLE', 'SPECIFIC',
                                     'PARTIAL_VIOLATION_SELECTION'):
            # Layer 2: Explicitly marked as full — but verify with actual amounts
            if total_violation_balance > Decimal('0') and payment_amount_dec < total_violation_balance:
                is_partial = True
                logger.warning(
                    f"paymentType='{payment_type}' says FULL but "
                    f"paymentAmount={payment_amount_dec} < "
                    f"totalViolationBalance={total_violation_balance}. "
                    f"Treating as PARTIAL (amount-based override)."
                )
            else:
                is_partial = False
                logger.info(
                    f"Full payment confirmed via paymentType='{payment_type}'. "
                    f"paymentAmount={payment_amount_dec}, "
                    f"totalViolationBalance={total_violation_balance}"
                )
        else:
            # Layer 3: Unknown payment type — determine from amounts
            if total_violation_balance > Decimal('0') and payment_amount_dec < total_violation_balance:
                is_partial = True
                logger.warning(
                    f"Unknown paymentType='{payment_type}'. "
                    f"Determined PARTIAL from amounts: "
                    f"payment={payment_amount_dec} < balance={total_violation_balance}"
                )
            else:
                is_partial = False
                logger.info(
                    f"Unknown paymentType='{payment_type}'. "
                    f"Determined FULL from amounts: "
                    f"payment={payment_amount_dec}, balance={total_violation_balance}"
                )

        logger.info(
            f"Payment routing decision: is_partial={is_partial}, "
            f"paymentType='{payment_type}', paymentAmount={payment_amount_dec}, "
            f"totalViolationBalance={total_violation_balance}"
        )
        # ──────────────────────────────────────────────────────────
        # END OF PAYMENT ROUTING BLOCK
        # ──────────────────────────────────────────────────────────

        api_url = os.environ.get('VIOLATION_API_URL', 'MOCK_MODE')
        api_key = get_api_key()
        use_dynamodb = (api_url == 'MOCK_MODE' or api_key == 'MOCK_MODE')

        if is_partial:
            # ── Partial payment: distribute oldest-first ──
            results = apply_partial_payment(
                violation_ids=violation_ids,
                violation_amounts=violation_amounts,
                total_payment=float(payment_amount),
                transaction_id=transaction_id,
                customer_id=customer_id,
                client_id=client_id,
                account_number=account_number,
                use_dynamodb=use_dynamodb,
                api_url=api_url,
                api_key=api_key
            )
            updated    = results['updated']
            failed     = results['failed']
            total_paid = results['total_paid']

        else:
            # ── Full payment: pay each violation in full ──
            updated    = []
            failed     = []
            total_paid = Decimal('0')

            for i, violation_id in enumerate(violation_ids):
                amount = (
                    violation_amounts[i]
                    if i < len(violation_amounts)
                    else str(float(payment_amount) / len(violation_ids))
                )

                success = update_violation(
                    violation_id=violation_id,
                    amount_paid=amount,
                    payment_status='PAID_IN_FULL',
                    transaction_id=transaction_id,
                    customer_id=customer_id,
                    client_id=client_id,
                    account_number=account_number,
                    use_dynamodb=use_dynamodb,
                    api_url=api_url,
                    api_key=api_key
                )

                if success:
                    updated.append(violation_id)
                    total_paid += Decimal(str(amount))
                else:
                    failed.append(violation_id)

        # Update customer totalBalance
        if updated and use_dynamodb:
            update_customer_balance(
                customer_id=customer_id,
                client_id=client_id,
                amount_paid=total_paid,
                transaction_id=transaction_id
            )

        total     = len(violation_ids)
        n_updated = len(updated)
        n_failed  = len(failed)

        if n_failed == 0:
            update_status = 'SUCCESS'
            message = f"Successfully updated {n_updated} of {total} violations"
        elif n_updated == 0:
            update_status = 'FAILED'
            message = f"Failed to update all {total} violations"
        else:
            update_status = 'PARTIAL'
            message = f"Updated {n_updated} of {total} violations. {n_failed} failed."

        logger.info(f"Result: {message}")

        return {
            'updateStatus':      update_status,
            'updatedViolations': str(n_updated),
            'failedViolations':  ','.join(failed),
            'updateMessage':     message
        }

    except Exception as e:
        logger.error(f"Error in UpdateViolationBalance: {type(e).__name__}: {str(e)}", exc_info=True)
        return {
            'updateStatus': 'FAILED', 'updatedViolations': '0',
            'failedViolations': '', 'updateMessage': f'Unexpected error: {str(e)}'
        }


def update_violation(
    violation_id, amount_paid, payment_status, transaction_id,
    customer_id, client_id, account_number, use_dynamodb, api_url, api_key
):
    """Update a single violation record."""
    logger.info(
        f"Updating violation {violation_id}: "
        f"amount={amount_paid}, status={payment_status}"
    )

    if use_dynamodb:
        return update_violation_dynamodb(
            violation_id=violation_id,
            amount_paid=amount_paid,
            payment_status=payment_status,
            transaction_id=transaction_id,
            customer_id=customer_id,
            client_id=client_id,
            account_number=account_number
        )

    # ── Production API path (future) ─────────────────────────
    # Security: Bandit B310 / CWE-22 remediated via validate_url()
    # and sanitize_path_segment() before any network call.
    # ──────────────────────────────────────────────────────────
    try:
        # Sanitise violation_id: allow only alphanumeric, hyphens, underscores
        safe_violation_id = sanitize_path_segment(violation_id)

        target_url = f"{api_url}/violations/{safe_violation_id}/payment"

        # Validate full URL before opening (remediates Bandit B310 / CWE-22)
        validate_url(target_url)

        payload = json.dumps({
            'violationId':   violation_id,
            'amountPaid':    amount_paid,
            'paymentStatus': payment_status,
            'transactionId': transaction_id,
            'customerId':    customer_id,
            'clientId':      client_id,
            'accountNumber': account_number
        }).encode('utf-8')

        req = urllib.request.Request(
            url=target_url,
            data=payload,
            method='POST',
            headers={
                'Content-Type':     'application/json',
                'Authorization':    f'Bearer {api_key}',
                'X-Transaction-Id': transaction_id
            }
        )

        with urllib.request.urlopen(req, timeout=10) as response:  # nosec B310 — URL validated by validate_url() above
            body = json.loads(response.read().decode('utf-8'))
            return response.status == 200 and body.get('success', False)

    except ValueError as ve:
        logger.error(
            f"URL/input validation failed for violation {violation_id}: {ve}"
        )
        return False
    except Exception as e:
        logger.error(
            f"API error for {violation_id}: "
            f"{type(e).__name__}: {str(e)}"
        )
        return False


def update_violation_dynamodb(
    violation_id, amount_paid, payment_status, transaction_id,
    customer_id, client_id, account_number
):
    """
    Write payment result to DynamoDB.

    KEY FIX: Now correctly manages balanceRemaining field.
    - PAID_IN_FULL: sets balanceRemaining = 0, status = PAID
    - PARTIAL_PAYMENT: decrements balanceRemaining, status = PARTIAL
      (auto-promotes to PAID if balanceRemaining hits 0)
    """
    try:
        table = dynamodb.Table(VIOLATIONS_TABLE)
        now   = datetime.now(timezone.utc).isoformat()
        pk    = f"CLIENT#{client_id}#VIOL#{violation_id}"

        payment_entry = {
            'transactionId': transaction_id,
            'amountPaid'   : Decimal(str(amount_paid)),
            'paymentStatus': payment_status,
            'accountNumber': account_number,
            'paidAt'       : now
        }

        if payment_status == 'PAID_IN_FULL':
            # ── Full payment: balance goes to zero ──
            violation_status = 'PAID'

            response = table.update_item(
                Key={'PK': pk, 'SK': 'DETAILS'},
                UpdateExpression=(
                    'SET #st = :status, '
                    'updatedAt = :now, '
                    'balanceRemaining = :zero, '
                    'paymentHistory = list_append('
                    '  if_not_exists(paymentHistory, :empty), '
                    '  :payment'
                    ')'
                ),
                ExpressionAttributeNames={'#st': 'status'},
                ExpressionAttributeValues={
                    ':status' : violation_status,
                    ':now'    : now,
                    ':zero'   : Decimal('0'),
                    ':payment': [payment_entry],
                    ':empty'  : []
                },
                ReturnValues='UPDATED_NEW'
            )

        else:
            # ── Partial payment: decrement balanceRemaining ──
            # First read the current record to get current balance
            current_item = table.get_item(
                Key={'PK': pk, 'SK': 'DETAILS'}
            ).get('Item', {})

            # If balanceRemaining doesn't exist yet, initialize
            # from the violation's amount field
            current_balance = Decimal(str(
                current_item.get(
                    'balanceRemaining',
                    current_item.get('amount', 0)
                )
            ))

            new_balance = current_balance - Decimal(str(amount_paid))

            # Guard against going negative
            if new_balance < Decimal('0'):
                logger.warning(
                    f"Balance would go negative for {violation_id}: "
                    f"current={current_balance}, paid={amount_paid}. "
                    f"Clamping to 0."
                )
                new_balance = Decimal('0')

            # Auto-promote to PAID if fully paid off
            if new_balance == Decimal('0'):
                violation_status = 'PAID'
                logger.info(
                    f"Violation {violation_id} fully paid off "
                    f"via partial payments. Promoting to PAID."
                )
            else:
                violation_status = 'PARTIAL'

            response = table.update_item(
                Key={'PK': pk, 'SK': 'DETAILS'},
                UpdateExpression=(
                    'SET #st = :status, '
                    'updatedAt = :now, '
                    'balanceRemaining = :new_bal, '
                    'paymentHistory = list_append('
                    '  if_not_exists(paymentHistory, :empty), '
                    '  :payment'
                    ')'
                ),
                ExpressionAttributeNames={'#st': 'status'},
                ExpressionAttributeValues={
                    ':status'  : violation_status,
                    ':now'     : now,
                    ':new_bal' : new_balance,
                    ':payment' : [payment_entry],
                    ':empty'   : []
                },
                ReturnValues='UPDATED_NEW'
            )

        logger.info(
            f"DynamoDB updated violation {violation_id} → "
            f"status={violation_status}, amount_paid={amount_paid}"
        )
        logger.info(f"Updated attributes: {response.get('Attributes', {})}")
        return True

    except Exception as e:
        logger.error(
            f"DynamoDB update failed for {violation_id}: "
            f"{type(e).__name__}: {str(e)}",
            exc_info=True
        )
        return False


def update_customer_balance(customer_id, client_id, amount_paid, transaction_id):
    """Decrement totalBalance on the customer PROFILE record."""
    try:
        table = dynamodb.Table(CUSTOMERS_TABLE)
        pk    = f"CLIENT#{client_id}#CUST#{customer_id}"
        now   = datetime.now(timezone.utc).isoformat()

        response = table.update_item(
            Key={'PK': pk, 'SK': 'PROFILE'},
            UpdateExpression=(
                'SET updatedAt = :now, '
                'totalBalance = if_not_exists(totalBalance, :zero) - :amount'
            ),
            ConditionExpression='attribute_exists(PK)',
            ExpressionAttributeValues={
                ':amount': Decimal(str(amount_paid)),
                ':now'   : now,
                ':zero'  : Decimal('0')
            },
            ReturnValues='UPDATED_NEW'
        )

        new_balance = response.get('Attributes', {}).get('totalBalance', 'unknown')
        logger.info(
            f"Customer {customer_id} totalBalance decremented by {amount_paid}. "
            f"New balance: {new_balance}"
        )
        return True

    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        logger.error(f"Customer record not found: PK={pk}")
        return False
    except Exception as e:
        logger.error(f"Failed to update customer balance: {type(e).__name__}: {str(e)}", exc_info=True)
        return False


def apply_partial_payment(
    violation_ids, violation_amounts, total_payment, transaction_id,
    customer_id, client_id, account_number, use_dynamodb, api_url, api_key
):
    """Distribute partial payment across violations oldest first."""
    updated    = []
    failed     = []
    remaining  = Decimal(str(total_payment))
    total_paid = Decimal('0')

    for i, violation_id in enumerate(violation_ids):
        if remaining <= 0:
            break

        violation_amount = Decimal(str(
            violation_amounts[i] if i < len(violation_amounts) else 0
        ))
        if violation_amount <= 0:
            continue

        if remaining >= violation_amount:
            amount_to_pay  = violation_amount
            payment_status = 'PAID_IN_FULL'
            remaining     -= violation_amount
        else:
            amount_to_pay  = remaining
            payment_status = 'PARTIAL_PAYMENT'
            remaining      = Decimal('0')

        success = update_violation(
            violation_id=violation_id,
            amount_paid=str(amount_to_pay),
            payment_status=payment_status,
            transaction_id=transaction_id,
            customer_id=customer_id,
            client_id=client_id,
            account_number=account_number,
            use_dynamodb=use_dynamodb,
            api_url=api_url,
            api_key=api_key
        )

        if success:
            updated.append(violation_id)
            total_paid += amount_to_pay
        else:
            failed.append(violation_id)

    return {'updated': updated, 'failed': failed, 'total_paid': total_paid}


def get_slot_value(slots, slot_name):
    if not slots or slot_name not in slots or slots[slot_name] is None:
        return None
    slot = slots[slot_name]
    if 'value' in slot and slot['value']:
        return slot['value'].get('interpretedValue', None)
    return None
