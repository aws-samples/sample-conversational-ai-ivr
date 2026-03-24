const { 
  QConnectClient, 
  UpdateSessionDataCommand 
} = require('@aws-sdk/client-qconnect');

const { 
  ConnectClient, 
  DescribeContactCommand 
} = require('@aws-sdk/client-connect');

const qConnectClient = new QConnectClient();
const connectClient  = new ConnectClient({ 
  region: process.env.AWS_REGION 
});

const ContextKeys = {
  AI_ASSISTANT_ID     : 'AI_ASSISTANT_ID',
  CONNECT_INSTANCE_ID : 'CONNECT_INSTANCE_ID',
};

// ── Attributes to sync into Q Connect session ──────────────
// These come from Contact Attributes set by the Connect flow
const TARGET_ATTRIBUTES = [
  'clientId',
  'clientName',
  'clientType',
  'availableTools',
  'authMethod',
  'isOpen',
  'maxViolationsIVR',
  'escalationQueue',
  'greetingMessage',
  'settlementEnabled',
  'paymentHandling',
  'transferNumber'
];

// ── Attributes that must NEVER be overridden by the loop ───
// We set these explicitly with resolved values
const PROTECTED_ATTRIBUTES = [
  'sessionId',
  'initialContactId',
  'currentContactId',
  'wisdomSessionId',
  'connectContactId'
];

// ── Attributes to exclude from the catch-all loop ──────────
const RESERVED_KEYS = [
  'AI_ASSISTANT_ID',
  'CONNECT_INSTANCE_ID'
];


// ── Logging helper ─────────────────────────────────────────
const log = (level, message, data) => {
  const entry = { 
    level, 
    message, 
    timestamp: new Date().toISOString() 
  };
  if (data) entry.params = data;
  console.log(JSON.stringify(entry));
};


/**
 * Gets the Q Connect (Wisdom) session ARN from the Connect contact.
 * Returns both the full ARN and the extracted Wisdom session ID.
 * 
 * IMPORTANT: The Wisdom session ID extracted here is ONLY used
 * for making Q Connect API calls. It must NEVER be used as the
 * business session key (sessionId attribute).
 */
const getAssistantSession = async (connectContactId, connectInstanceId) => {
  log('DEBUG', 'Getting assistant session ARN', { 
    connectContactId, 
    connectInstanceId 
  });

  const command = new DescribeContactCommand({
    ContactId : connectContactId,
    InstanceId: connectInstanceId,
  });

  const response = await connectClient.send(command);

  if (!response.Contact?.WisdomInfo?.SessionArn) {
    throw new Error(
      `No Q Connect session found for contact ${connectContactId}. ` +
      `Ensure Q Connect is enabled for this contact flow.`
    );
  }

  const sessionArn = response.Contact.WisdomInfo.SessionArn;

  // Extract Wisdom session ID from ARN
  // ARN format: arn:aws:wisdom:region:account:session/assistant-id/session-id
  const wisdomSessionId = sessionArn.split('/').pop();

  log('DEBUG', 'Found session ARN', { 
    sessionArn,
    wisdomSessionId,
    connectContactId,
    note: 'wisdomSessionId used ONLY for API calls, NOT as business sessionId'
  });

  return { sessionArn, wisdomSessionId };
};


/**
 * Gets required environment variable or throws.
 */
const getRequiredEnvVar = (key) => {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
};


/**
 * Validates that a value is a real resolved ID and not a literal
 * Connect flow expression like "$.ContactId".
 * 
 * This catches the case where Set Initial Attributes in the Connect
 * flow failed to resolve the dynamic reference and stored the
 * literal string instead of the actual UUID.
 */
const isUnresolvedExpression = (value) => {
  if (!value) return true;
  // Detect unresolved Connect flow expressions
  if (String(value).startsWith('$.')) return true;
  // Detect empty or whitespace
  if (String(value).trim() === '') return true;
  return false;
};


/**
 * Validates that a value looks like a Connect ContactId UUID.
 * Connect ContactIds are standard UUIDs.
 */
const isValidContactId = (value) => {
  if (!value) return false;
  const uuidPattern = 
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  return uuidPattern.test(String(value).trim());
};


/**
 * Builds the key-value pairs to write into the Q Connect session.
 * 
 * FIX: Explicitly sets sessionId, initialContactId, and 
 * currentContactId using the CONNECT ContactId (passed as parameter),
 * NOT the Wisdom session ID (used only for API calls).
 * 
 * Also validates that no unresolved Connect expressions like
 * "$.ContactId" are written into the session.
 */
const buildKeyValuePairs = (connectRequest, connectContactId) => {
  const contactAttributes = 
    connectRequest.Details?.ContactData?.Attributes || {};
  
  const parameters = 
    connectRequest.Details?.Parameters || {};

  log('DEBUG', 'Building key-value pairs', { 
    connectContactId,
    contactAttributeKeys: Object.keys(contactAttributes),
    parameterKeys       : Object.keys(parameters)
  });

  const keyValuePairs = [];

  // ── STEP 1: Set contact ID attributes explicitly ──────────
  // FIX: These MUST use the Connect ContactId, not Wisdom ID.
  // We set them first so the loop below cannot override them.
  
  const contactIdAttributes = {
    // The canonical session key used by all Lambdas and DynamoDB
    'sessionId'       : connectContactId,
    // Aliases for compatibility with different parts of the system
    'initialContactId': connectContactId,
    'currentContactId': connectContactId,
    // Store Wisdom ID separately so it is available if needed
    // but clearly labelled so it is never confused with Contact ID
    'wisdomSessionId' : null, // Set after we get the ARN - see handler
    'connectContactId': connectContactId,
  };

  for (const [key, value] of Object.entries(contactIdAttributes)) {
    // Skip null entries (wisdomSessionId set later)
    if (value === null) continue;

    // Validate the value is a real UUID, not an expression
    if (isUnresolvedExpression(value)) {
      log('ERROR', `UNRESOLVED EXPRESSION detected for ${key}`, { 
        value,
        connectContactId,
        action: 'Using connectContactId as fallback'
      });
      // Fall back to the native ContactId from ContactData
      keyValuePairs.push({
        key  : key,
        value: { stringValue: connectContactId }
      });
    } else {
      keyValuePairs.push({
        key  : key,
        value: { stringValue: String(value) }
      });
    }

    log('DEBUG', `Set protected attribute: ${key}`, { value });
  }


  // ── STEP 2: Add TARGET_ATTRIBUTES from contact attributes ─
  for (const key of TARGET_ATTRIBUTES) {
    // Skip - already handled in Step 1
    if (PROTECTED_ATTRIBUTES.includes(key)) continue;

    const value = contactAttributes[key];

    if (!value || String(value).trim() === '') continue;

    // Check for unresolved Connect flow expressions
    if (isUnresolvedExpression(value)) {
      log('WARN', `Skipping unresolved expression for ${key}`, { value });
      continue;
    }

    keyValuePairs.push({
      key  : key,
      value: { stringValue: String(value) }
    });

    log('DEBUG', `Added target attribute: ${key}`, { value });
  }


  // ── STEP 3: Add remaining contact attributes (catch-all) ──
  // FIX: Skip PROTECTED_ATTRIBUTES so they cannot be overridden
  // by whatever value happens to be in the contact attributes.
  for (const [key, value] of Object.entries(contactAttributes)) {
    
    // Skip reserved system keys
    if (RESERVED_KEYS.includes(key)) continue;
    
    // Skip target attributes (already handled in Step 2)
    if (TARGET_ATTRIBUTES.includes(key)) continue;
    
    // FIX: Skip protected attributes (already set in Step 1)
    // This prevents the contact attribute value of sessionId
    // (which may be unresolved "$.ContactId") from overriding
    // what we explicitly set above.
    if (PROTECTED_ATTRIBUTES.includes(key)) {
      log('DEBUG', `Skipping protected attribute in catch-all: ${key}`, { 
        contactAttrValue: value,
        protectedValue  : connectContactId,
        reason          : 'Protected attribute already set explicitly'
      });
      continue;
    }

    if (!value || String(value).trim() === '') continue;

    // Check for unresolved Connect flow expressions
    if (isUnresolvedExpression(value)) {
      log('WARN', `Skipping unresolved expression in catch-all: ${key}`, { 
        value 
      });
      continue;
    }

    keyValuePairs.push({
      key  : key,
      value: { stringValue: String(value) }
    });

    log('DEBUG', `Added additional attribute: ${key}`, { value });
  }

  return keyValuePairs;
};


/**
 * Updates the Q Connect session with the provided key-value pairs.
 * 
 * FIX: Takes both wisdomSessionId (for the API call) and 
 * connectContactId (for logging and verification only).
 * These are different IDs serving different purposes.
 */
const updateSessionData = async (
  aiAssistantId, 
  wisdomSessionId,    // Used ONLY for the Q Connect API call
  connectContactId,   // Used ONLY for logging/verification
  keyValuePairs
) => {
  // Verify sessionId in keyValuePairs is the Connect ContactId
  // not the Wisdom session ID
  const sessionIdPair = keyValuePairs.find(kv => kv.key === 'sessionId');
  const sessionIdValue = sessionIdPair?.value?.stringValue;

  log('INFO', 'SESSION ID AUDIT', {
    connectContactId,
    wisdomSessionId,
    sessionIdBeingWritten : sessionIdValue,
    isCorrect             : sessionIdValue === connectContactId,
    areIdsDifferent       : connectContactId !== wisdomSessionId,
    explanation: (
      'connectContactId should be written as sessionId. ' +
      'wisdomSessionId is used only for the API call. ' +
      'They must be different values.'
    )
  });

  // Alert if session ID mismatch detected
  if (sessionIdValue !== connectContactId) {
    log('ERROR', 'CRITICAL: sessionId being written does not match connectContactId', {
      sessionIdBeingWritten : sessionIdValue,
      connectContactId,
      action: 'This will cause session restore failures'
    });
  }

  // Alert if Wisdom ID accidentally equals Connect ID
  // (should never happen but worth detecting)
  if (wisdomSessionId === connectContactId) {
    log('WARN', 'wisdomSessionId equals connectContactId - unusual, investigate', {
      wisdomSessionId,
      connectContactId
    });
  }

  const command = new UpdateSessionDataCommand({
    assistantId: aiAssistantId,
    sessionId  : wisdomSessionId,    // ← Wisdom ID for API call
    data       : keyValuePairs,
  });

  log('INFO', 'Updating Q Connect session', { 
    assistantId    : aiAssistantId, 
    wisdomSessionId: wisdomSessionId,   // ← What Q Connect API uses
    connectId      : connectContactId,  // ← What business logic uses
    attributeCount : keyValuePairs.length,
    attributes     : keyValuePairs.map(kv => kv.key)
  });

  await qConnectClient.send(command);

  log('INFO', 'Session data updated successfully', {
    wisdomSessionId,
    connectContactId,
    sessionIdWritten: sessionIdValue
  });
};


/**
 * Main handler - invoked by Amazon Connect Contact Flow
 */
exports.handler = async (connectRequest) => {
  const contactId = connectRequest.Details?.ContactData?.ContactId;
  const channel   = connectRequest.Details?.ContactData?.Channel;
  const initialContactId = 
    connectRequest.Details?.ContactData?.InitialContactId;

  log('INFO', 'Lambda invoked', { 
    contactId,
    initialContactId,
    channel,
    idsMatch: contactId === initialContactId
  });

  try {
    // ── Validate ContactId ──────────────────────────────────
    if (!contactId) {
      throw new Error('Missing ContactId in request');
    }

    // FIX: Validate it looks like a real UUID, not an expression
    if (!isValidContactId(contactId)) {
      log('ERROR', 'ContactId does not look like a valid UUID', { 
        contactId,
        action: 'This may indicate a Connect flow configuration issue'
      });
    }

    // ── Get environment variables ───────────────────────────
    const aiAssistantId    = getRequiredEnvVar(ContextKeys.AI_ASSISTANT_ID);
    const connectInstanceId = getRequiredEnvVar(ContextKeys.CONNECT_INSTANCE_ID);

    // ── Get Q Connect session ───────────────────────────────
    // Returns BOTH the ARN and the extracted Wisdom session ID
    const { sessionArn, wisdomSessionId } = 
      await getAssistantSession(contactId, connectInstanceId);

    log('INFO', 'ID Resolution Summary', {
      connectContactId : contactId,       // ← Business session key
      wisdomSessionId  : wisdomSessionId, // ← Q Connect API key only
      areTheyDifferent : contactId !== wisdomSessionId,
      note: 'connectContactId will be written as sessionId attribute'
    });

    // ── Build key-value pairs ───────────────────────────────
    // FIX: Pass connectContactId explicitly so it is set
    // as the sessionId regardless of what is in contact attributes
    const keyValuePairs = buildKeyValuePairs(connectRequest, contactId);

    // ── Add wisdomSessionId to the pairs ────────────────────
    // Store it separately for reference/debugging
    // It is clearly labelled so it cannot be confused with
    // the business sessionId
    keyValuePairs.push({
      key  : 'wisdomSessionId',
      value: { stringValue: wisdomSessionId }
    });

    if (keyValuePairs.length === 0) {
      log('WARN', 'No attributes found to update', {
        contactAttributes: 
          connectRequest.Details?.ContactData?.Attributes
      });
      return {
        statusCode   : 200,
        status       : 'NO_ATTRIBUTES',
        message      : 'No attributes found to update',
        attributesSet: 0
      };
    }

    log('INFO', 'Attributes prepared for Q Connect update', { 
      count     : keyValuePairs.length,
      attributes: keyValuePairs.map(kv => kv.key)
    });

    // ── Update Q Connect session ────────────────────────────
    // FIX: Pass both IDs explicitly so the function
    // uses wisdomSessionId for the API call and
    // connectContactId for verification logging
    await updateSessionData(
      aiAssistantId,
      wisdomSessionId,  // ← For Q Connect API call
      contactId,        // ← For audit logging only
      keyValuePairs
    );

    // ── Return success ──────────────────────────────────────
    const response = {
      statusCode     : 200,
      status         : 'SUCCESS',
      attributesSet  : keyValuePairs.length,
      attributes     : keyValuePairs.map(kv => kv.key).join(','),
      connectContactId: contactId,        // Echo for Connect flow verification
      wisdomSessionId : wisdomSessionId,  // Echo for debugging
      sessionIdWritten: contactId         // Confirm what was written as sessionId
    };

    log('INFO', 'Lambda completed successfully', response);
    return response;

  } catch (error) {
    log('ERROR', 'Lambda execution failed', { 
      error: error.message,
      stack: error.stack,
      contactId
    });

    return {
      statusCode: 500,
      status    : 'ERROR',
      error     : error.message
    };
  }
};