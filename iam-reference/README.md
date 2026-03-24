# IAM Reference Policies

Snapshots of IAM policies from the live environment, provided for reference during deployment and troubleshooting.

**These are NOT used directly by CloudFormation.** CFN templates define their own IAM roles and policies. These files document the actual working state.

## Structure

```
iam-reference//
    trust-policy.json           # Lambda assume role trust policy
    managed-policies.json       # Attached AWS managed policies
    inline-*.json              # Custom inline policies (DynamoDB, Connect, etc.)
```