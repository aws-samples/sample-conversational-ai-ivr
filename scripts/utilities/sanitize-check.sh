#!/bin/bash
# =============================================================================
# Pre-commit secret scanner for ConversationalIVR project
# Usage: ./scripts/utilities/sanitize-check.sh
# =============================================================================

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ERRORS=0
SAFE="123456789012|111111111111|PLACEHOLDER|REPLACE_WITH|xxxxxxxx|XXXXXXXXXX|your-|000000000000|example"

echo "Scanning for secrets in ${REPO_ROOT}..."
echo ""

echo "--- [1/5] AWS Account IDs ---"
F=$(grep -rn '[0-9]\{12\}' "${REPO_ROOT}" \
    --include="*.py" --include="*.js" --include="*.json" \
    --include="*.yaml" --include="*.sh" \
    --exclude-dir=.git 2>/dev/null \
    | grep -Ev "${SAFE}|sanitize-check" \
    | grep -E '[0-9]{12}' || true)
if [ -n "$F" ]; then
    echo "  WARNING:"
    echo "$F"
    ERRORS=$((ERRORS+1))
else
    echo "  OK"
fi

echo "--- [2/5] Hardcoded ARNs ---"
F=$(grep -rn 'arn:aws:' "${REPO_ROOT}" \
    --include="*.py" --include="*.js" --include="*.sh" \
    --exclude-dir=.git 2>/dev/null \
    | grep -Ev "${SAFE}|# ARN" || true)
if [ -n "$F" ]; then
    echo "  WARNING:"
    echo "$F"
    ERRORS=$((ERRORS+1))
else
    echo "  OK"
fi

echo "--- [3/5] .env files ---"
F=$(find "${REPO_ROOT}" -name ".env" \
    -not -name ".env.example" \
    -not -path "*/.git/*" 2>/dev/null || true)
if [ -n "$F" ]; then
    echo "  WARNING:"
    echo "$F"
    ERRORS=$((ERRORS+1))
else
    echo "  OK"
fi

echo "--- [4/5] UUIDs in source ---"
F=$(grep -rn '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' "${REPO_ROOT}" \
    --include="*.py" --include="*.js" --include="*.sh" \
    --exclude-dir=.git 2>/dev/null \
    | grep -Ev "${SAFE}" || true)
if [ -n "$F" ]; then
    echo "  WARNING:"
    echo "$F"
    ERRORS=$((ERRORS+1))
else
    echo "  OK"
fi

echo "--- [5/5] S3 buckets with account IDs ---"
F=$(grep -rn 's3://.*[0-9]\{12\}' "${REPO_ROOT}" \
    --include="*.py" --include="*.js" \
    --include="*.yaml" --include="*.sh" \
    --exclude-dir=.git 2>/dev/null \
    | grep -Ev "${SAFE}" || true)
if [ -n "$F" ]; then
    echo "  WARNING:"
    echo "$F"
    ERRORS=$((ERRORS+1))
else
    echo "  OK"
fi

echo ""
if [ $ERRORS -gt 0 ]; then
    echo "FAILED: ${ERRORS} issue(s) found. Fix before committing."
    exit 1
else
    echo "PASSED: No secrets detected."
    exit 0
fi