# =============================================================================
# VERIFY WEBHOOK CONNECTION: Azure DevOps Incoming Webhook + Pipeline Access
# =============================================================================
# Validates:
#   1. Service connection exists
#   2. Service connection type is incoming webhook
#   3. Webhook name matches expected value (case-sensitive)
#   4. Pipeline permissions include the target pipeline OR all pipelines
# =============================================================================

param(
    [string]$OrganizationUrl       = "https://dev.azure.com/3Cloud",
    [string]$Project               = "DevSecOps SRE Community Sandbox",
    [string]$ConnectionName        = "SREAlertWebhookConnection738",
    [string]$ExpectedWebhookName   = "ContainerAppAlert",
    [int]$PipelineId               = 738,
    [string]$AzureDevOpsPat        = $env:AZURE_DEVOPS_EXT_PAT
)

$ErrorActionPreference = "Stop"

if ($AzureDevOpsPat) {
    $env:AZURE_DEVOPS_EXT_PAT = $AzureDevOpsPat
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VERIFY WEBHOOK CONNECTION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Organization URL:     $OrganizationUrl"
Write-Host "  Project:              $Project"
Write-Host "  Connection Name:      $ConnectionName"
Write-Host "  Expected Webhook:     $ExpectedWebhookName"
Write-Host "  Target Pipeline ID:   $PipelineId"
Write-Host ""

$endpointFound = $false
$typeOk = $false
$webhookNameOk = $false
$pipelineAuthorized = $false
$allPipelinesAuthorized = $false
$effectiveAuthorized = $false
$permissionsChecked = $false

$endpointId = ""
$endpointType = ""
$actualWebhookName = ""
$permissionCheckDetail = ""

Write-Host "Fetching service connection..." -ForegroundColor Gray
$endpointListRaw = az devops service-endpoint list `
    --organization $OrganizationUrl `
    --project $Project `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to list service endpoints. Azure DevOps CLI output: $($endpointListRaw | Out-String)"
    exit 1
}

$endpointList = $endpointListRaw | ConvertFrom-Json
$endpoint = $endpointList | Where-Object { $_.name -eq $ConnectionName } | Select-Object -First 1

if ($endpoint) {
    $endpointFound = $true
    $endpointId = $endpoint.id
    $endpointType = $endpoint.type
    $actualWebhookName = $endpoint.data.WebhookName

    $typeOk = ($endpointType -eq "incomingwebhook")
    $webhookNameOk = ($actualWebhookName -ceq $ExpectedWebhookName)
} else {
    $permissionCheckDetail = "Service connection '$ConnectionName' not found or not visible to your identity."
}

if ($endpointFound) {
    if (-not $AzureDevOpsPat) {
        $permissionCheckDetail = "Cannot verify pipeline permissions because AZURE_DEVOPS_EXT_PAT is not set."
    } else {
        Write-Host "Checking pipeline permissions for service connection..." -ForegroundColor Gray

        $permissionsChecked = $true
        $projectEncoded = [System.Uri]::EscapeDataString($Project)
        $basicAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AzureDevOpsPat"))
        $headers = @{
            Authorization = "Basic $basicAuth"
        }

        $permissionsUri = "$OrganizationUrl/$projectEncoded/_apis/pipelines/pipelinePermissions/endpoint/$endpointId?api-version=7.1-preview.1"

        try {
            $permissions = Invoke-RestMethod -Method GET -Uri $permissionsUri -Headers $headers
            $allPipelinesAuthorized = [bool]$permissions.allPipelines.authorized
            $pipelineAuthorized = @($permissions.pipelines | Where-Object { $_.id -eq $PipelineId -and $_.authorized }).Count -gt 0
            $effectiveAuthorized = ($allPipelinesAuthorized -or $pipelineAuthorized)
        } catch {
            $permissionCheckDetail = "Pipeline permission check failed: $($_.Exception.Message)"
        }
    }
}

$summary = [ordered]@{
    "Service Connection Exists"      = if ($endpointFound) { "PASS" } else { "FAIL" }
    "Type Incoming Webhook"          = if ($typeOk) { "PASS" } else { "FAIL" }
    "Webhook Name Exact Match"       = if ($webhookNameOk) { "PASS" } else { "FAIL" }
    "Pipeline $PipelineId Authorized"= if ($pipelineAuthorized) { "PASS" } else { "FAIL" }
    "All Pipelines Authorized"       = if ($allPipelinesAuthorized) { "PASS" } else { "FAIL" }
    "Effective Authorization"        = if ($effectiveAuthorized) { "PASS" } else { "FAIL" }
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  VERIFICATION RESULT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "  Endpoint ID:             $endpointId" -ForegroundColor White
Write-Host "  Endpoint Type:           $endpointType" -ForegroundColor White
Write-Host "  Actual Webhook Name:     $actualWebhookName" -ForegroundColor White
Write-Host ""

foreach ($k in $summary.Keys) {
    $value = $summary[$k]
    $color = if ($value -eq "PASS") { "Green" } else { "Red" }
    Write-Host ("  {0,-28}: {1}" -f $k, $value) -ForegroundColor $color
}

if ($permissionCheckDetail) {
    $color = if ($permissionsChecked) { "DarkYellow" } else { "Yellow" }
    Write-Host "" 
    Write-Host "  Detail: $permissionCheckDetail" -ForegroundColor $color
}

$overallPass = (
    $endpointFound -and
    $typeOk -and
    $webhookNameOk -and
    $effectiveAuthorized
)

Write-Host ""
if ($overallPass) {
    Write-Host "OVERALL: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "OVERALL: FAIL" -ForegroundColor Red
exit 1
