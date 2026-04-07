# Deployment Guide

## Prerequisites

- AWS CLI v2 configured with appropriate credentials
- Python 3.12+, Node.js 20.x+
- Amazon Connect instance created
- Bedrock model access enabled (Nova Sonic)
- An S3 bucket for CloudFormation templates (referenced in `env.sh`)
- **API Gateway CloudWatch Logs role** — one-time setup per account/region (see [README prerequisites](../README.md#prerequisites))

---

## Step 1: Configure Environment

Both `deploy-all.sh` and `env.sh` must be in the **root** of the project folder.

```bash
cp env.sh.example env.sh
# Edit env.sh with your AWS account details
```

> **Important:** After any change to `env.sh`, always re-source it before running scripts:
> ```bash
> source env.sh
> ```
> Forgetting to re-source is a common cause of deployment failures (e.g., stale instance alias causing `AlreadyExists` errors).

### Connect Instance Alias

If you get an `AlreadyExists` error for the Connect instance alias during deployment, change `INSTANCE_ALIAS` in `env.sh` to a unique value and re-source the file.

---

## Step 2: Deploy CloudFormation Stacks (Phased)

Run the master deployment script:

```bash
./deploy-all.sh
```

The script deploys in multiple phases. Review the confirmation prompt before each phase.

### Phase 0 — Backend Infrastructure

Deploys DynamoDB tables, Lambda functions (stubs), and API Gateway:

| Stack | Template |
|-------|----------|
| anycompany-ivr-client-config | 01a-client-config-table.yaml |
| anycompany-ivr-dynamodb | 01b-dynamodb-tables.yaml |
| anycompany-ivr-session-table | 01c-session-table.yaml |
| anycompany-ivr-lambdas | 02a-tool-lambdas.yaml |
| anycompany-ivr-payments-lambdas | 02d-payments-lambdas.yaml |
| anycompany-ivr-fulfillment-hook | 02f-fulfillment-hook.yaml |
| anycompany-ivr-getCallAttributes | 02b-getCallAttributes.yaml |
| anycompany-ivr-api | 03-api-gateway.yaml |

After Phase 0, the script automatically updates `openapi.yaml` with the real API Gateway URL.

### Phase 1 — Connect + AgentCore + Q in Connect

Uploads nested templates to S3 and deploys the root nested stack:

| Stack | Template |
|-------|----------|
| anycompany-ivr (root) | root.yaml (nests connect-instance, connect-config, agentcore-gateway, agentcore-target, bootstrap, mcp-application) |

### Phase 1b — Connect-Dependent Stacks

Deploys stacks that require the Connect instance from Phase 1:

| Stack | Template |
|-------|----------|
| anycompany-ivr-payment-handoff | 02e-payment-handoff-resources.yaml |
| anycompany-ivr-update-session | 02c-ConnectAssistantUpdateSessionData.yaml |
| anycompany-ivr-agent-screen-pop | agent-screen-pop-view.yaml |

### ⏸️ Manual Steps Required Before Phase 2 - Follow **Manual-post-phase1-and-phase2-deployment-steps.md**

The script pauses here. Complete the following before pressing ENTER to continue:


### Phase 2 — AI Agent Configuration

After completing the manual steps above, press ENTER. The script deploys:

| Stack | Template |
|-------|----------|
| anycompany-ivr-phase2-qagents | qagents-v49.yaml |

This configures 13 tool definitions (9 MCP + 2 RTC + 2 payment) for the AI agent.

---

## Step 3: Post-Phase 2 Manual Steps - Follow **Manual-post-phase1-and-phase2-deployment-steps.md**


## Troubleshooting Notes

### AgentCore Gateway Permission Errors

If you see `GetResourceApiKey` or `secretsmanager:GetSecretValue` 403 errors in AgentCore Gateway logs, the gateway role needs additional permissions. Run:

```bash
./fix-agentcore-gateway-permission.sh
```

If a second error appears for Secrets Manager access, run:

```bash
./fix-agentcore-secrets-permission.sh
```

### AI Agent Not Responding

If the AI agent created by Phase 2 automation doesn't work correctly, create a new AI Agent manually in the Connect console:
- Attach the same prompt and all tools
- Set it as the "Self Service" default under Default AI Agent Configurations

### Connect Flow Issues

See the [Connect Flow Update Process](../README.md#connect-flow-update-process) section in the README and [Troubleshooting](troubleshooting.md) for common flow issues.

---

## Deployment Summary (12 Stacks)

| Phase | Stacks |
|-------|--------|
| Phase 0 | anycompany-ivr-client-config, anycompany-ivr-dynamodb, anycompany-ivr-session-table, anycompany-ivr-lambdas, anycompany-ivr-payments-lambdas, anycompany-ivr-fulfillment-hook, anycompany-ivr-getCallAttributes, anycompany-ivr-api |
| Phase 1 | anycompany-ivr (root + nested stacks) |
| Phase 1b | anycompany-ivr-payment-handoff, anycompany-ivr-update-session, anycompany-ivr-agent-screen-pop |
| Phase 2 | anycompany-ivr-phase2-qagents |
