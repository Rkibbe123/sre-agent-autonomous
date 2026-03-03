# =============================================================================
# CREATE WEBHOOK TRIGGER: Azure Monitor → Azure DevOps Pipeline
# =============================================================================
# This script sets up the end-to-end webhook flow:
#   1. Creates an "Incoming Webhook" service connection in Azure DevOps
#   2. Adds a webhook action to the EXISTING Action Group
#   3. Verifies the existing Log Alert Rules are connected
#
# When an alert fires: Azure Monitor → Action Group → Webhook → Pipeline
#
# Prerequisites:
#   - az CLI logged in (az login)
#   - Azure DevOps PAT with "Service Connections (Read & Manage)" scope
#   - Contributor role on the subscription (for Action Group update)
# =============================================================================

param(
    [string]$Organization      = "3Cloud",
    [string]$Project           = "DevSecOps SRE Community Sandbox",
    [string]$PipelineId        = "731",
    [string]$SubscriptionId    = "d5736eb1-f851-4ec3-a2c5-ac8d84d029e2",
    [string]$ResourceGroup     = "rg-rkibbe-2470",
    [string]$ContainerAppName  = "azure-resource-inventory",
    [string]$WebhookName       = "ContainerAppAlert",
    [string]$ConnectionName    = "SREAlertWebhookConnection",
    [string]$ActionGroupName   = "az-resource-action-grp",
    [string[]]$AlertRuleNames  = @(
        "dev-ai-5xx-high",
        "dev-ai-response-slow",
        "dev-ai-plan-cpu-high",
        "dev-ai-plan-mem-high"
    )
)

$ErrorActionPreference = "Stop"

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
    Write-Error "Failed to get project ID. Make sure you're logged in: az devops login"
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
    } catch {
        Write-Host "  Failed to create via REST API. Error: $_" -ForegroundColor Red
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
    --subscription $SubscriptionId 2>$null

if (-not $existingAG) {
    Write-Error "Action Group '$ActionGroupName' not found in $ResourceGroup. Please verify the name and resource group."
    exit 1
}

Write-Host "  Action Group found. Adding webhook action..." -ForegroundColor Green

# Update the existing action group to include the SRE pipeline webhook
az monitor action-group update `
    --name $ActionGroupName `
    --resource-group $ResourceGroup `
    --subscription $SubscriptionId `
    --add-action webhook sre-pipeline-trigger $webhookUrl `
    --output none

Write-Host "  Webhook 'sre-pipeline-trigger' added to '$ActionGroupName'." -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 3: Verify Alert Rules Are Connected to the Action Group
# =============================================================================
Write-Host "─── STEP 3: Verify Alert Rules ───" -ForegroundColor Yellow
Write-Host ""

$actionGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/actionGroups/$ActionGroupName"

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
            az monitor scheduled-query update `
                --name $ruleName `
                --resource-group $ResourceGroup `
                --subscription $SubscriptionId `
                --action-groups $actionGroupId `
                --output none 2>$null
            Write-Host "      Done." -ForegroundColor Green
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
                az monitor metrics alert update `
                    --name $ruleName `
                    --resource-group $ResourceGroup `
                    --subscription $SubscriptionId `
                    --add-action $actionGroupId `
                    --output none 2>$null
                Write-Host "      Done." -ForegroundColor Green
            }
        } else {
            Write-Host "    ✗ '$ruleName' NOT FOUND — skipping" -ForegroundColor Red
        }
    }
}
Write-Host ""

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host "============================================" -ForegroundColor Green
Write-Host "  SETUP COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
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
