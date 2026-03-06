# SRE Autonomous Agent Pipeline

An Azure DevOps pipeline that automatically **reviews Web App logs**, **diagnoses root causes**, **generates code fixes**, and **creates Pull Requests** in the [`ai-app-svcs`](https://dev.azure.com/3Cloud/DevSecOps%20SRE%20Community%20Sandbox/_git/ai-app-svcs) repo — triggered by webhook alerts from your Web App.

Built on the same **Azure SRE Agent** + **Azure OpenAI** patterns used in `sre-agent`, with `AzureCLI@2` + PowerShell Core + `Invoke-SREAgentAPI` for all AI interactions.

## Architecture

```
Web App Error ──► Webhook ──► Azure DevOps Pipeline
                                         │
                                         ├─ 🔍 Stage 1: Review Logs
                                         │     SRE Agent queries Web App logs
                                         │     from Log Analytics (KQL), analyzes errors
                                         │
                                         ├─ 🔬 Stage 2: Diagnose Root Cause
                                         │     Clone ai-app-svcs, correlate logs w/ code
                                         │
                                         ├─ 🛠️ Stage 3: Generate Code Fix
                                         │     Azure OpenAI writes fix, validates, pushes
                                         │
                                         └─ 📋 Stage 4: Create Pull Request
                                               PR in ai-app-svcs with logs + analysis
```

## Repository Structure

```
├── azure-pipelines.yml              # Main pipeline definition
├── templates/
│   ├── sre-agent-common.yml         # Shared helpers (from sre-agent repo)
│   ├── detect-failure.yml           # Stage 1: Web App log query & analysis
│   ├── diagnose-root-cause.yml      # Stage 2: Log-to-code correlation & diagnosis
│   ├── propose-fix.yml              # Stage 3: AI code fix generation & validation
│   └── create-pull-request.yml      # Stage 4: PR creation in ai-app-svcs
└── README.md
```

## Prerequisites

### Azure SRE Agent
- SRE Agent resource provisioned (`Microsoft.App/agents`)
- Agent name: `rkibbe` in resource group `rg-rkibbe-2470`
- Endpoint: `https://rkibbe--88208374.4650bed8.eastus2.azuresre.ai`

### Azure OpenAI
- Endpoint: `https://rkibbe-chat-demo-resource.openai.azure.com/openai/v1/responses`
- Deployment: `agentic-deveops-agent` (gpt-5.3-codex)
- Authenticated via Azure service connection (no API key needed)

### Azure DevOps
- Service connection: `azure-devops-sp2` (with Contributor + SRE Agent Operator role)
- Variable group: `databricks-dab-pipeline` linked to the pipeline
- `System.AccessToken` used for repo clone + PR creation (no separate PAT required)
- Pipeline permissions: **Code** Read/Write, **Pull Requests** Read/Write on `ai-app-svcs`

### Web App
- Web App: `dev-ai-app-svcs-web` in resource group `rg-rkibbe-2470`
- Log Analytics workspace connected via the Web App diagnostics configuration
- The pipeline defaults to workspace `2898ab68-ba5c-4175-a5a2-437b4f7b97f0` for this repo

## Setup

### 1. Link Variable Group

The pipeline uses the existing `databricks-dab-pipeline` variable group. Ensure it's linked to this pipeline.

The Azure OpenAI endpoint and deployment are hardcoded in the pipeline variables:

| Variable | Value |
|---|---|
| `azureOpenAIEndpoint` | `https://rkibbe-chat-demo-resource.openai.azure.com/openai/v1/responses` |
| `azureOpenAIDeployment` | `agentic-deveops-agent` |
| `sre_agent_resource_group` | `rg-rkibbe-2470` |
| `sre_agent_name` | `rkibbe` |

### 2. Configure Webhook Trigger (Automated)

Run the setup script to add the webhook to your existing action group and verify alert rules:

```powershell
./setup/create-webhook-trigger.ps1
```

This does:
1. **Creates Incoming Webhook Service Connection** (`SREAlertWebhookConnection738`) in Azure DevOps
2. **Adds webhook action** to existing Action Group `az-resource-action-grp`
3. **Verifies** the following alert rules are connected to the action group:
   - `dev-ai-5xx-high`
   - `dev-ai-response-slow`
   - `dev-ai-plan-cpu-high`
   - `dev-ai-plan-mem-high`

**Flow:**
```
Alert Rule (any of 4) → az-resource-action-grp → Incoming Webhook → Pipeline #738
```

**Webhook URL:**
```
https://dev.azure.com/3Cloud/_apis/public/distributedtask/webhooks/ContainerAppAlert?api-version=6.0-preview
```

The pipeline auto-maps Azure Monitor's Common Alert Schema severity (`Sev0`–`Sev4`) to pipeline severity (`critical`/`high`/`medium`/`low`).

**Manual Fallback:** You can still trigger the pipeline manually via the REST API:
```
POST https://dev.azure.com/3Cloud/DevSecOps%20SRE%20Community%20Sandbox/_apis/pipelines/738/runs?api-version=7.1
```

```json
{
  "templateParameters": {
    "serviceName": "dev-ai-app-svcs-web",
    "severity": "high",
    "incidentId": "INC-12345",
    "containerAppName": "dev-ai-app-svcs-web",
    "containerAppResourceGroup": "rg-rkibbe-2470"
  }
}
```

> **Note:** This repo defaults `logAnalyticsWorkspace` to `2898ab68-ba5c-4175-a5a2-437b4f7b97f0`.

### 3. Import Pipeline

1. Go to **Pipelines** → **New Pipeline**
2. Select your repo containing this code
3. Choose **Existing Azure Pipelines YAML file**
4. Select `azure-pipelines.yml`
5. Grant the pipeline **access to the `databricks-dab-pipeline` variable group**
6. Grant the build service identity **Contribute + Create Branch** permissions on target repos

## Pipeline Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `alertPayload` | Yes | `{}` | JSON alert from your monitoring webhook |
| `targetProject` | No | `DevSecOps SRE Community Sandbox` | Azure DevOps project containing the target repo |
| `targetRepo` | Yes | `ai-app-svcs` | Repository name within your Azure DevOps project |
| `targetBranch` | No | `main` | Branch to base the fix on |
| `serviceName` | No | `dev-ai-app-svcs-web` | Name of the affected service |
| `severity` | No | `high` | Alert severity: critical, high, medium, low |
| `incidentId` | No | `AUTO` | Incident/alert tracking ID |
| `containerAppName` | No | `dev-ai-app-svcs-web` | Azure Web App name |
| `containerAppResourceGroup` | No | `rg-rkibbe-2470` | Resource group of the Web App |
| `logAnalyticsWorkspace` | No | `2898ab68-ba5c-4175-a5a2-437b4f7b97f0` | Log Analytics workspace ID |
| `logTimespan` | No | `PT1H` | How far back to query logs (ISO 8601 duration) |

## How It Works

### Stage 1 — Review Web App Logs
- Parses the incoming webhook alert payload
- Queries the app's **console logs** (`ContainerAppConsoleLogs_CL`) and **system logs** (`ContainerAppSystemLogs_CL`) from Log Analytics via KQL
- Uses the configured Log Analytics workspace ID (`2898ab68-ba5c-4175-a5a2-437b4f7b97f0`)
- SRE Agent analyzes the combined logs + alert to extract: error signature, affected component, stack trace patterns
- Gates the pipeline if the issue is not code-actionable (infrastructure/transient)

### Stage 2 — Diagnose Root Cause
- Clones the [`ai-app-svcs`](https://dev.azure.com/3Cloud/DevSecOps%20SRE%20Community%20Sandbox/_git/ai-app-svcs) repository
- Maps the repo structure and identifies recently changed files
- Searches for source files related to the error signature from the logs
- Azure OpenAI **correlates runtime logs with the source code** to identify the exact root cause
- Outputs: root cause explanation, affected file list, and suggested fix

### Stage 3 — Generate Code Fix
- Creates a fix branch (`sre-agent/fix-{buildId}`)
- Azure OpenAI generates fixed versions of affected files based on the log-derived root cause
- Runs language-appropriate validation (Python/Node.js/.NET/Go linting, syntax checks, tests)
- Commits and pushes the fix branch to `ai-app-svcs`

### Stage 4 — Create Pull Request
- Creates a PR in `ai-app-svcs` via the Azure DevOps REST API
- Rich description includes: Web App logs excerpt, root cause analysis, code changes, and validation results
- Labels the PR (`sre-agent`, `severity-{level}`, `auto-generated`)
- Optionally enables auto-complete for low-severity issues

## Supported Languages

The validation step auto-detects project type and runs appropriate checks:

| Language | Lint | Build | Test |
|---|---|---|---|
| Python | flake8 | py_compile | pytest |
| Node.js/TypeScript | ESLint | tsc --noEmit | npm test |
| .NET | — | dotnet build | dotnet test |
| Go | go vet | go build | go test |

## Safety

- **Human review required**: All PRs require manual review before merge (except low-severity with auto-complete)
- **Draft mode available**: Set `isDraft: True` in the PR creation for extra safety
- **Validation gates**: The pipeline runs lint/syntax/test checks before creating the PR
- **Severity-gated auto-complete**: Only `low` severity PRs get auto-complete enabled
- **Audit trail**: Every PR links back to the pipeline run with full analysis artifacts