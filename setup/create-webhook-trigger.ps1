# =============================================================================
# CREATE WEBHOOK TRIGGER: Azure Monitor → Azure DevOps Pipeline
# =============================================================================
# This script sets up the end-to-end webhook flow:
#   1. Creates an "Incoming Webhook" service connection in Azure DevOps
#   2. Adds a webhook action to the EXISTING Action Group
#   3. Verifies the existing Log Alert Rules are connected
#   4. Tests webhook trigger delivery to Azure DevOps
#
# When an alert fires: Azure Monitor → Action Group → Webhook → Pipeline
#
# Prerequisites:
#   - az CLI logged in (az login)
#   - Azure DevOps authentication via:
#       * AZURE_DEVOPS_EXT_PAT environment variable, or
#       * az devops login
#     PAT requires "Service Connections (Read & Manage)" scope
#   - Contributor role on the subscription (for Action Group update)
# =============================================================================

param(
    [string]$Organization      = "3Cloud",
    [string]$Project           = "DevSecOps SRE Community Sandbox",
    [string]$PipelineId        = "738",
    [string]$SubscriptionId    = "d5736eb1-f851-4ec3-a2c5-ac8d84d029e2",
    [string]$ResourceGroup     = "rg-rkibbe-2470",
    [string]$ContainerAppName  = "azure-resource-inventory",
    [string]$WebhookName       = "ContainerAppAlert",
    [string]$ConnectionName    = "SREAlertWebhookConnection738",
    [string]$ActionGroupName   = "az-resource-action-grp",
    [string]$AzureDevOpsPat    = $env:AZURE_DEVOPS_EXT_PAT,
    [int]$WebhookTestRetries   = 3,
    [int]$WebhookTestDelaySec  = 3,
    [string[]]$AlertRuleNames  = @(
        "dev-ai-5xx-high",
        "dev-ai-response-slow",
        "dev-ai-plan-cpu-high",
        "dev-ai-plan-mem-high"
    )
)

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$verification = [ordered]@{
    "Service Connection" = "FAIL"
    "Action Group Webhook" = "FAIL"
    "Alert Rules" = "FAIL"
    "Webhook Trigger Test" = "FAIL"
}

$webhookTestResultDetail = "Not run"

# ── Helper: URL-encode the project name ──
$projectEncoded = [System.Uri]::EscapeDataString($Project)
$orgUrl = "https://dev.azure.com/$Organization"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  SRE AGENT WEBHOOK TRIGGER SETUP" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Organization:   $Organization"
Write-Host "  Project:        $Project"
Write-Host "  Pipeline:       $PipelineId"
Write-Host "  Container App:  $ContainerAppName"
Write-Host "  Resource Group: $ResourceGroup"
Write-Host ""

if ($AzureDevOpsPat) {
    $env:AZURE_DEVOPS_EXT_PAT = $AzureDevOpsPat
    Write-Host "  Azure DevOps auth: PAT from parameter/environment" -ForegroundColor Green
} else {
    Write-Host "  Azure DevOps auth: no PAT provided; falls back to existing az devops login context" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# STEP 1: Create Azure DevOps Incoming Webhook Service Connection
# =============================================================================
Write-Host "─── STEP 1: Create Incoming Webhook Service Connection ───" -ForegroundColor Yellow
Write-Host ""

# Get the project ID
Write-Host "  Fetching project ID..." -ForegroundColor Gray
$projectId = az devops project show `
    --organization $orgUrl `
    --project $Project `
    --query id -o tsv

if (-not $projectId) {
    Write-Error "Failed to get project ID. Provide -AzureDevOpsPat (or set AZURE_DEVOPS_EXT_PAT), or run: az devops login"
    exit 1
}
Write-Host "  Project ID: $projectId" -ForegroundColor Green

# Check if service connection already exists
$existingEndpoints = az devops service-endpoint list `
    --organization $orgUrl `
    --project $Project `
    --query "[?name=='$ConnectionName'].id" -o tsv

if ($existingEndpoints) {
    Write-Host "  Service connection '$ConnectionName' already exists (ID: $existingEndpoints)" -ForegroundColor Green
    Write-Host "  Skipping creation." -ForegroundColor Gray
    $verification["Service Connection"] = "PASS"
} else {
    Write-Host "  Creating Incoming Webhook service connection..." -ForegroundColor Gray

    # The az CLI doesn't have a built-in command for incoming webhook connections,
    # so we use the REST API directly
    $body = @{
        name = $ConnectionName
        type = "incomingwebhook"
        url  = $orgUrl
        data = @{
            WebhookName = $WebhookName
        }
        authorization = @{
            scheme     = "None"
            parameters = @{}
        }
        serviceEndpointProjectReferences = @(
            @{
                projectReference = @{
                    id   = $projectId
                    name = $Project
                }
                name = $ConnectionName
            }
        )
    } | ConvertTo-Json -Depth 10

    $token = az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" --query accessToken -o tsv
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type"  = "application/json"
    }

    try {
        $endpoint = Invoke-RestMethod `
            -Uri "$orgUrl/_apis/serviceendpoint/endpoints?api-version=7.1" `
            -Method POST `
            -Headers $headers `
            -Body $body

        Write-Host "  Service connection created: $($endpoint.id)" -ForegroundColor Green
        $verification["Service Connection"] = "PASS"
    } catch {
        Write-Host "  Failed to create via REST API. Error: $_" -ForegroundColor Red
        Write-Host "  Re-checking whether service connection now exists..." -ForegroundColor Gray

        $recheckSucceeded = $false
        $recheckErrorDetail = ""
        $recheckAttempts = 3

        for ($i = 1; $i -le $recheckAttempts; $i++) {
            Write-Host "  Service connection re-check attempt $i of $recheckAttempts..." -ForegroundColor Gray

            $recheckOutput = az devops service-endpoint list `
                --organization $orgUrl `
                --project $Project `
                --query "[?name=='$ConnectionName'].id" -o tsv 2>&1

            if ($LASTEXITCODE -eq 0) {
                $recheckSucceeded = $true
                $recheckEndpointId = ($recheckOutput | Out-String).Trim()
                if ($recheckEndpointId) {
                    Write-Host "  Service connection '$ConnectionName' found after retry check (ID: $recheckEndpointId)." -ForegroundColor Green
                    $verification["Service Connection"] = "PASS"
                } else {
                    $recheckErrorDetail = "Service endpoint query succeeded, but no service connection named '$ConnectionName' exists in project '$Project'."
                }
                break
            }

            $recheckErrorDetail = ($recheckOutput | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($recheckErrorDetail)) {
                $recheckErrorDetail = "Unknown Azure DevOps CLI error during re-check"
            }

            if ($i -lt $recheckAttempts) {
                Start-Sleep -Seconds 2
            }
        }

        if (-not $recheckSucceeded -or -not $recheckEndpointId) {
            if ($recheckErrorDetail -match "forcibly closed|ConnectionReset|connection reset|transport connection|SSL connection") {
                Write-Host "  Re-check failed due to transport/TLS connectivity to Azure DevOps." -ForegroundColor Red
            } elseif ($recheckErrorDetail -match "login command|az devops login|credentials") {
                Write-Host "  Re-check failed due to Azure DevOps authentication/credentials." -ForegroundColor Red
            } else {
                Write-Host "  Re-check failed due to Azure DevOps CLI/API error." -ForegroundColor Red
            }
            Write-Host "  Re-check detail: $recheckErrorDetail" -ForegroundColor DarkYellow

            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
            Write-Host "  ║ MANUAL FALLBACK: Create it in the Azure DevOps portal   ║" -ForegroundColor Yellow
            Write-Host "  ║                                                          ║" -ForegroundColor Yellow
            Write-Host "  ║ 1. Project Settings → Service connections → New          ║" -ForegroundColor Yellow
            Write-Host "  ║ 2. Choose 'Incoming Webhook'                             ║" -ForegroundColor Yellow
            Write-Host "  ║ 3. Webhook Name:     $WebhookName               ║" -ForegroundColor Yellow
            Write-Host "  ║ 4. Connection Name:  $ConnectionName  ║" -ForegroundColor Yellow
            Write-Host "  ║ 5. Secret:           (leave blank)                       ║" -ForegroundColor Yellow
            Write-Host "  ║ 6. HTTP Header:      (leave blank)                       ║" -ForegroundColor Yellow
            Write-Host "  ║ 7. Grant access to all pipelines → Save                  ║" -ForegroundColor Yellow
            Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
        }
    }
}

# The webhook URL that Azure Monitor will POST to
$webhookUrl = "$orgUrl/_apis/public/distributedtask/webhooks/${WebhookName}?api-version=6.0-preview"
Write-Host ""
Write-Host "  Webhook URL (for Action Group):" -ForegroundColor Cyan
Write-Host "  $webhookUrl" -ForegroundColor White
Write-Host ""

# =============================================================================
# STEP 2: Add Webhook Action to Existing Action Group
# =============================================================================
Write-Host "─── STEP 2: Add Webhook to Action Group '$ActionGroupName' ───" -ForegroundColor Yellow
Write-Host ""

# Verify the action group exists
$existingAG = az monitor action-group show `
    --name $ActionGroupName `
    --resource-group $ResourceGroup `
    --subscription $SubscriptionId -o json 2>&1
$existingAGExit = $LASTEXITCODE

if ($existingAGExit -ne 0 -or [string]::IsNullOrWhiteSpace(($existingAG | Out-String))) {
    Write-Error "Unable to read Action Group '$ActionGroupName' in '$ResourceGroup'. Azure CLI output: $($existingAG | Out-String)"
    exit 1
}

Write-Host "  Action Group found. Adding webhook action..." -ForegroundColor Green

# Update the existing action group to include the SRE pipeline webhook
$step2Output = az monitor action-group update `
    --name $ActionGroupName `
    --resource-group $ResourceGroup `
    --subscription $SubscriptionId `
    --add-action webhook sre-pipeline-trigger $webhookUrl `
    --output none 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "  Webhook 'sre-pipeline-trigger' added to '$ActionGroupName'." -ForegroundColor Green
} elseif (($step2Output | Out-String) -match "DuplicateWebhookServiceUri") {
    Write-Host "  Webhook already exists on '$ActionGroupName' (DuplicateWebhookServiceUri). Treating as success." -ForegroundColor Green
} else {
    Write-Host "  Failed to add webhook action to '$ActionGroupName'." -ForegroundColor Red
    Write-Host "  $step2Output" -ForegroundColor Red
}

# Verify webhook URI exists in the action group after update attempt
$webhookMatch = az monitor action-group show `
    --name $ActionGroupName `
    --resource-group $ResourceGroup `
    --subscription $SubscriptionId `
    --query "contains(webhookReceivers[].serviceUri, '$webhookUrl')" -o tsv 2>$null

if ($webhookMatch -eq "true") {
    $verification["Action Group Webhook"] = "PASS"
    Write-Host "  Verified webhook URI is present on '$ActionGroupName'." -ForegroundColor Green
} else {
    Write-Host "  Webhook URI not found on '$ActionGroupName' after update attempt." -ForegroundColor Red
}
Write-Host ""

# =============================================================================
# STEP 3: Verify Alert Rules Are Connected to the Action Group
# =============================================================================
Write-Host "─── STEP 3: Verify Alert Rules ───" -ForegroundColor Yellow
Write-Host ""

$actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/actionGroups/$ActionGroupName"
$allRulesHealthy = $true

foreach ($ruleName in $AlertRuleNames) {
    Write-Host "  Checking '$ruleName'..." -ForegroundColor Gray

    # Try scheduled-query (log alerts) first, then metric alerts
    $ruleJson = az monitor scheduled-query show `
        --name $ruleName `
        --resource-group $ResourceGroup `
        --subscription $SubscriptionId 2>$null

    if ($ruleJson) {
        $rule = $ruleJson | ConvertFrom-Json
        $linkedAGs = $rule.actions.actionGroups
        if ($linkedAGs -and ($linkedAGs -contains $actionGroupId)) {
            Write-Host "    ✓ '$ruleName' → linked to '$ActionGroupName'" -ForegroundColor Green
        } else {
            Write-Host "    ⚠ '$ruleName' exists but NOT linked to '$ActionGroupName'" -ForegroundColor Yellow
            Write-Host "      Linking now..." -ForegroundColor Gray
            $null = az monitor scheduled-query update `
                --name $ruleName `
                --resource-group $ResourceGroup `
                --subscription $SubscriptionId `
                --action-groups $actionGroupId `
                --output none 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "      Done." -ForegroundColor Green
            } else {
                Write-Host "      Failed to link '$ruleName' to '$ActionGroupName'." -ForegroundColor Red
                $allRulesHealthy = $false
            }
        }
    } else {
        # Try metric alert
        $metricRule = az monitor metrics alert show `
            --name $ruleName `
            --resource-group $ResourceGroup `
            --subscription $SubscriptionId 2>$null

        if ($metricRule) {
            Write-Host "    ✓ '$ruleName' found (metric alert)" -ForegroundColor Green
            # Check if action group is linked
            $parsed = $metricRule | ConvertFrom-Json
            $hasAG = $parsed.actions | Where-Object { $_.actionGroupId -eq $actionGroupId }
            if ($hasAG) {
                Write-Host "      → already linked to '$ActionGroupName'" -ForegroundColor Green
            } else {
                Write-Host "      ⚠ NOT linked to '$ActionGroupName' — adding..." -ForegroundColor Yellow
                $null = az monitor metrics alert update `
                    --name $ruleName `
                    --resource-group $ResourceGroup `
                    --subscription $SubscriptionId `
                    --add-action $actionGroupId `
                    --output none 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "      Done." -ForegroundColor Green
                } else {
                    Write-Host "      Failed to link '$ruleName' to '$ActionGroupName'." -ForegroundColor Red
                    $allRulesHealthy = $false
                }
            }
        } else {
            Write-Host "    ✗ '$ruleName' NOT FOUND — skipping" -ForegroundColor Red
            $allRulesHealthy = $false
        }
    }
}

if ($allRulesHealthy) {
    $verification["Alert Rules"] = "PASS"
}
Write-Host ""

# =============================================================================
# STEP 4: Test Webhook Trigger Delivery
# =============================================================================
Write-Host "─── STEP 4: Test Webhook Trigger Delivery ───" -ForegroundColor Yellow
Write-Host ""

$webhookTestPayload = '{"data":{"essentials":{"severity":"Sev2","alertRule":"test","description":"Manual test from setup script"}}}'
$webhookTestSucceeded = $false

for ($attempt = 1; $attempt -le $WebhookTestRetries; $attempt++) {
    Write-Host "  Test attempt $attempt of $WebhookTestRetries..." -ForegroundColor Gray

    try {
        $null = Invoke-RestMethod `
            -Uri $webhookUrl `
            -Method POST `
            -ContentType "application/json" `
            -Body $webhookTestPayload

        $webhookTestSucceeded = $true
        $webhookTestResultDetail = "Request accepted"
        Write-Host "  Webhook test request accepted." -ForegroundColor Green
        break
    } catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        if ($statusCode -ge 400 -and $statusCode -lt 500) {
            $webhookTestResultDetail = "HTTP $statusCode (client error)"
            Write-Host "  Webhook test failed: $webhookTestResultDetail" -ForegroundColor Red
        } elseif ($statusCode -ge 500) {
            $webhookTestResultDetail = "HTTP $statusCode (server error)"
            Write-Host "  Webhook test failed: $webhookTestResultDetail" -ForegroundColor Red
        } else {
            $errorText = $_.Exception.Message
            if ($errorText -match "forcibly closed|ConnectionReset|connection reset|transport connection") {
                $webhookTestResultDetail = "Transport reset"
            } else {
                $webhookTestResultDetail = "Transport error"
            }
            Write-Host "  Webhook test failed: $webhookTestResultDetail" -ForegroundColor Red
            Write-Host "  Error detail: $errorText" -ForegroundColor DarkYellow
        }

        if ($attempt -lt $WebhookTestRetries) {
            Write-Host "  Retrying in $WebhookTestDelaySec second(s)..." -ForegroundColor Gray
            Start-Sleep -Seconds $WebhookTestDelaySec
        }
    }
}

if ($webhookTestSucceeded) {
    $verification["Webhook Trigger Test"] = "PASS"
} else {
    Write-Host "  Webhook trigger test did not succeed after $WebhookTestRetries attempt(s)." -ForegroundColor Red
}
Write-Host ""

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VERIFICATION SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

foreach ($component in $verification.Keys) {
    $result = $verification[$component]
    $color = if ($result -eq "PASS") { "Green" } else { "Red" }
    Write-Host ("  {0,-22}: {1}" -f $component, $result) -ForegroundColor $color
}

$overallPass = ($verification.Values -notcontains "FAIL")
Write-Host ""
if ($overallPass) {
    Write-Host "  OVERALL: PASS" -ForegroundColor Green
} else {
    Write-Host "  OVERALL: FAIL" -ForegroundColor Red
}

Write-Host "  Webhook Test Detail: $webhookTestResultDetail" -ForegroundColor White

Write-Host ""
Write-Host "  Flow:" -ForegroundColor Cyan
Write-Host "    Any of these alert rules:" -ForegroundColor White
foreach ($r in $AlertRuleNames) {
Write-Host "      • $r" -ForegroundColor White
}
Write-Host "       └─► Action Group: $ActionGroupName" -ForegroundColor White
Write-Host "            └─► Webhook:  $WebhookName" -ForegroundColor White
Write-Host "                 └─► Pipeline #$PipelineId auto-triggers" -ForegroundColor White
Write-Host ""
Write-Host "  Webhook URL:" -ForegroundColor Cyan
Write-Host "    $webhookUrl" -ForegroundColor White
Write-Host ""
Write-Host "  To test manually:" -ForegroundColor Yellow
Write-Host "    Invoke-RestMethod -Uri '$webhookUrl' ``" -ForegroundColor White
Write-Host "      -Method POST ``" -ForegroundColor White
Write-Host "      -ContentType 'application/json' ``" -ForegroundColor White
Write-Host "      -Body '{`"data`":{`"essentials`":{`"severity`":`"Sev2`",`"alertRule`":`"test`",`"description`":`"Manual test`"}}}'" -ForegroundColor White
Write-Host ""
