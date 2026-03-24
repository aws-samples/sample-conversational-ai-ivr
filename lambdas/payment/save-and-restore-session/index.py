import json
import boto3
import os
import logging
from datetime import datetime, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource('dynamodb')
table    = dynamodb.Table(os.environ['SESSION_TABLE_NAME'])


def lambda_handler(event, context):
    """
    Handles SAVE and RESTORE operations for session
    context during payment bot handoff.

    KEY FIX: Session key resolution order:
      1. sessionId   from Parameters (explicit, set by Connect flow)
      2. ContactId   from ContactData (Connect's native value)
      
    This ensures the DynamoDB key always matches what
    the Connect flow uses to look up the session.
    """
    logger.info("SaveAndRestoreSession invoked")

    try:
        details      = event.get('Details', {})
        parameters   = details.get('Parameters', {})
        contact_data = details.get('ContactData', {})
        operation    = parameters.get('operation', 'SAVE')

        # ── Resolve session key ───────────────────────────────
        # FIX: Use explicit sessionId from Parameters first.
        # This is what the Connect flow controls and passes in.
        # Fall back to ContactData.ContactId if not provided.
        
        native_contact_id   = contact_data.get('ContactId', '')
        native_initial_id   = contact_data.get('InitialContactId', '')
        param_session_id    = parameters.get('sessionId', '')
        param_contact_id    = parameters.get('currentContactId', '')

        # The session key we will actually use for DynamoDB
        session_key = (
            param_session_id        # Explicit from Connect flow (preferred)
            or param_contact_id     # currentContactId passed as param
            or native_contact_id    # Native ContactData fallback
        )

        # ── Diagnostic logging ────────────────────────────────
        # These logs let you find the mismatch in CloudWatch
        logger.info(
            f"[ID Resolution] "
            f"param_sessionId={param_session_id} | "
            f"param_contactId={param_contact_id} | "
            f"native_contactId={native_contact_id} | "
            f"native_initialId={native_initial_id} | "
            f"resolved_sessionKey={session_key} | "
            f"operation={operation}"
        )

        # ── Alert on mismatch ─────────────────────────────────
        # If these differ, you have a contact ID mismatch
        if param_session_id and native_contact_id:
            if param_session_id != native_contact_id:
                logger.warning(
                    f"[ID MISMATCH DETECTED] "
                    f"param_sessionId={param_session_id} "
                    f"!= native_contactId={native_contact_id}. "
                    f"Using param_sessionId as session key."
                )

        if not session_key:
            logger.error("No session key could be resolved")
            return {
                'status' : 'ERROR',
                'message': 'No session key found'
            }

        # ── Route to operation ────────────────────────────────
        if operation == 'SAVE':
            return save_session(
                session_key,
                native_contact_id,
                native_initial_id,
                contact_data,
                parameters
            )
        elif operation == 'RESTORE':
            return restore_session(
                session_key,
                native_contact_id,
                contact_data
            )
        else:
            logger.error(f"Unknown operation: {operation}")
            return {
                'status' : 'ERROR',
                'message': f'Unknown operation: {operation}'
            }

    except Exception as e:
        logger.error(
            f"Error in SaveAndRestoreSession: {str(e)}",
            exc_info=True
        )
        return {
            'status' : 'ERROR',
            'message': str(e)
        }


def save_session(
    session_key,        # Resolved DynamoDB key (used for lookup)
    native_contact_id,  # Raw ContactId from ContactData
    native_initial_id,  # Raw InitialContactId from ContactData
    contact_data,
    parameters
):
    """
    Save complete session context to DynamoDB.

    FIX: Writes using session_key (resolved from Parameters.sessionId)
         so RESTORE can find it using the same key.
         Stores both native IDs for full audit trail.
    """
    attributes = contact_data.get('Attributes', {})

    session_data = {
        # ── Primary key ───────────────────────────────────────
        # FIX: Use resolved session_key, NOT raw contact_id
        'contactId'  : session_key,
        'ttl'        : int(
            (datetime.utcnow() + timedelta(hours=2))
            .timestamp()
        ),
        'savedAt'    : datetime.utcnow().isoformat(),
        'operation'  : 'SAVE',

        # ── Store all ID variants for debugging ───────────────
        # Lets you audit exactly what happened if mismatch recurs
        'sessionKey'          : session_key,
        'nativeContactId'     : native_contact_id,
        'nativeInitialId'     : native_initial_id,
        'paramSessionId'      : parameters.get('sessionId', ''),
        'paramCurrentContactId': parameters.get(
            'currentContactId', ''
        ),
        'paramInitialContactId': parameters.get(
            'initialContactId', ''
        ),

        # ── Core IVR configuration ────────────────────────────
        'clientId'        : attributes.get('clientId', ''),
        'clientName'      : attributes.get('clientName', ''),
        'clientType'      : attributes.get('clientType', ''),
        'availableTools'  : attributes.get('availableTools', ''),
        'authMethod'      : attributes.get('authMethod', ''),
        'isOpen'          : attributes.get('isOpen', ''),
        'maxViolationsIVR': attributes.get('maxViolationsIVR', ''),
        'escalationQueue' : attributes.get('escalationQueue', ''),
        'greetingMessage' : attributes.get('greetingMessage', ''),

        # ── Customer context ──────────────────────────────────
        # FIX: Parameters take priority over attributes.
        # Lex session data in Parameters is more current
        # than contact attributes which may be stale.
        'customerId'   : (
            parameters.get('customerId', '')
            or attributes.get('customerId', '')
        ),
        'customerName' : (
            parameters.get('customerName', '')
            or attributes.get('customerName', '')
        ),
        'accountNumber': (
            parameters.get('accountNumber', '')
            or attributes.get('accountNumber', '')
        ),

        # ── Conversation context ──────────────────────────────
        'conversationSummary': parameters.get(
            'conversationSummary', ''
        ),
        'lastIntent'         : parameters.get('lastIntent', ''),

        # ── Payment context ───────────────────────────────────
        'paymentAmount': parameters.get('paymentAmount', ''),
        'paymentReason': parameters.get('paymentReason', ''),
        'paymentType'  : parameters.get('paymentType', ''),

        # ── Violation details ─────────────────────────────────
        'violationIds'    : (
            parameters.get('violationIds', '')
            or attributes.get('violationIds', '')
        ),
        'violationAmounts': (
            parameters.get('violationAmounts', '')
            or attributes.get('violationAmounts', '')
        ),

        # ── Contact metadata ──────────────────────────────────
        'customerEndpoint': contact_data.get(
            'CustomerEndpoint', {}
        ).get('Address', ''),
        'channel'         : contact_data.get('Channel', ''),
    }

    table.put_item(Item=session_data)

    logger.info(
        f"[SAVE SUCCESS] "
        f"sessionKey={session_key} | "
        f"nativeContactId={native_contact_id} | "
        f"violationIds={session_data['violationIds']} | "
        f"paymentAmount={session_data['paymentAmount']} | "
        f"paymentType={session_data['paymentType']}"
    )

    return {
        'status'          : 'SAVED',
        'sessionKey'      : session_key,        # Echo back for verification
        'contactId'       : native_contact_id,  # Native Connect value
        'paymentAmount'   : parameters.get('paymentAmount', '0'),
        'accountNumber'   : parameters.get('accountNumber', ''),
        'paymentReason'   : parameters.get('paymentReason', ''),
        'customerName'    : parameters.get('customerName', ''),
        'violationIds'    : parameters.get('violationIds', ''),
        'violationAmounts': parameters.get('violationAmounts', ''),
        'paymentType'     : parameters.get('paymentType', ''),
    }


def restore_session(
    session_key,        # Resolved DynamoDB key (must match SAVE)
    native_contact_id,  # Raw ContactId from ContactData
    contact_data
):
    """
    Restore saved session context and merge with
    payment results.

    FIX: Looks up using session_key (resolved from Parameters.sessionId)
         which MUST match what was used in save_session().
         
    If NOT_FOUND, attempts fallback lookup using native_contact_id
    so the flow can still recover gracefully.
    """
    logger.info(
        f"[RESTORE ATTEMPT] "
        f"sessionKey={session_key} | "
        f"nativeContactId={native_contact_id}"
    )

    # ── Primary lookup ────────────────────────────────────────
    response = table.get_item(
        Key={'contactId': session_key}
    )

    # ── Fallback lookup ───────────────────────────────────────
    # FIX: If primary key misses, try native_contact_id.
    # This handles the case where SAVE used a different key.
    # Logs clearly which key succeeded so you can fix the root cause.
    if 'Item' not in response and session_key != native_contact_id:
        logger.warning(
            f"[RESTORE FALLBACK] "
            f"Primary lookup missed for sessionKey={session_key}. "
            f"Trying nativeContactId={native_contact_id}"
        )
        response = table.get_item(
            Key={'contactId': native_contact_id}
        )
        if 'Item' in response:
            logger.warning(
                f"[RESTORE FALLBACK SUCCESS] "
                f"Found session using nativeContactId={native_contact_id}. "
                f"ROOT CAUSE: SAVE used key={native_contact_id} "
                f"but RESTORE was given key={session_key}. "
                f"Fix Set Initial Attributes in Connect flow."
            )

    # ── Not found after all attempts ──────────────────────────
    if 'Item' not in response:
        logger.error(
            f"[RESTORE FAILED] "
            f"No session found for "
            f"sessionKey={session_key} OR "
            f"nativeContactId={native_contact_id}"
        )
        return {
            'status'          : 'NOT_FOUND',
            'message'         : 'No saved session found',
            'clientId'        : '',
            'clientName'      : '',
            'clientType'      : '',
            'paymentCompleted': 'false',
        }

    item = response['Item']

    # ── Merge payment results ─────────────────────────────────
    # Payment results come from current contact attributes,
    # set by Connect after PaymentCollectionBot completed
    current_attrs  = contact_data.get('Attributes', {})
    payment_status = current_attrs.get('paymentStatus', 'unknown')
    transaction_id = current_attrs.get('transactionId', '')
    last4          = current_attrs.get('last4Digits', '')
    payment_amount = current_attrs.get(
        'paymentAmount',
        item.get('paymentAmount', '')
    )

    # Violation update results
    update_status      = current_attrs.get('updateStatus', '')
    updated_violations = current_attrs.get('updatedViolations', '')
    failed_violations  = current_attrs.get('failedViolations', '')

    restore_data = {
        'status': 'RESTORED',

        # ── Echo keys for Connect flow verification ───────────
        'sessionKey'    : session_key,
        'contactId'     : native_contact_id,

        # ── Core IVR configuration ────────────────────────────
        'clientId'        : str(item.get('clientId', '')),
        'clientName'      : str(item.get('clientName', '')),
        'clientType'      : str(item.get('clientType', '')),
        'availableTools'  : str(item.get('availableTools', '')),
        'authMethod'      : str(item.get('authMethod', '')),
        'isOpen'          : str(item.get('isOpen', '')),
        'maxViolationsIVR': str(item.get('maxViolationsIVR', '')),
        'escalationQueue' : str(item.get('escalationQueue', '')),
        'greetingMessage' : str(item.get('greetingMessage', '')),

        # ── Customer context ──────────────────────────────────
        'customerId'   : str(item.get('customerId', '')),
        'customerName' : str(item.get('customerName', '')),
        'accountNumber': str(item.get('accountNumber', '')),

        # ── Conversation context ──────────────────────────────
        'conversationSummary': str(
            item.get('conversationSummary', '')
        ),
        'lastIntent'         : str(item.get('lastIntent', '')),

        # ── Payment results ───────────────────────────────────
        'paymentStatus'   : payment_status,
        'transactionId'   : transaction_id,
        'last4Digits'     : last4,
        'paymentAmount'   : str(payment_amount),
        'paymentReason'   : str(item.get('paymentReason', '')),
        'paymentType'     : str(item.get('paymentType', '')),
        'paymentCompleted': (
            'true' if payment_status == 'success'
            else 'false'
        ),

        # ── Violation details ─────────────────────────────────
        'violationIds'    : str(item.get('violationIds', '')),
        'violationAmounts': str(item.get('violationAmounts', '')),

        # ── Violation update results ──────────────────────────
        'updateStatus'      : update_status,
        'updatedViolations' : updated_violations,
        'failedViolations'  : failed_violations,
    }

    # ── Clean up DynamoDB ─────────────────────────────────────
    # Delete using the key that was actually found
    found_key = item.get('contactId', session_key)
    table.delete_item(Key={'contactId': found_key})

    logger.info(
        f"[RESTORE SUCCESS] "
        f"sessionKey={session_key} | "
        f"foundWithKey={found_key} | "
        f"paymentStatus={payment_status} | "
        f"updateStatus={update_status} | "
        f"updatedViolations={updated_violations}"
    )

    return restore_data