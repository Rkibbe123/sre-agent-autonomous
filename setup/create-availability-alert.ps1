# =============================================================================
# CREATE AVAILABILITY WEB TEST + METRIC ALERT (App Insights -> Action Group)
# =============================================================================
# Creates/updates:
#   1) Application Insights availability (ping) web test
#   2) Metric alert on availabilityResults/availabilityPercentage < threshold
#
# Routes alert notifications to an existing Action Group, which can already
# contain your Azure DevOps incoming webhook receiver.
# =============================================================================

[CmdletBinding()]
param(
    [string]$SubscriptionId      = "d5736eb1-f851-4ec3-a2c5-ac8d84d029e2",
    [string]$ResourceGroup       = "rg-rkibbe-2470",
    [string]$Location            = "East US",

    [string]$AppInsightsName     = "dev-ai-app-svcs-web-ai",
    [string]$WebTestName         = "dev-ai-app-svcs-web-ping",
    [string]$WebTestUrl          = "https://dev-ai-app-svcs-web.azurewebsites.net/",
    [string]$WebTestDescription  = "Ping test for dev-ai-app-svcs-web",
    [string]$TestLocationId      = "us-va-ash-azr",
    [int]$FrequencySeconds       = 300,
    [int]$TimeoutSeconds         = 120,

    [string]$WebTestGuid         = "6f3e0f1d-8a5e-4c7c-9a4a-1c2b3d4e5f61",
    [string]$RequestGuid         = "8b2c6d7e-1234-4b5c-9abc-def012345678",

    [string]$AlertName           = "dev-ai-availability-alert",
    [double]$AvailabilityPercentThreshold = 100,
    [string]$WindowSize          = "5m",
    [string]$EvaluationFrequency = "1m",
    [int]$Severity               = 2,
    [string]$ActionGroupName     = "az-resource-action-grp",
    [string]$AlertDescription    = "Alert on availability < 100% for dev-ai-app-svcs-web-ping"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [switch]$AsJson,
        [switch]$AllowFailure,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 3
    )

    $cmdText = "az " + ($Arguments -join " ")
    Write-Host ">> $cmdText" -ForegroundColor DarkGray

    $attempt = 0
    $raw = $null
    $exitCode = 0
    $text = ""

    do {
        $attempt++
        $raw = & az @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($raw | Out-String).Trim()

        if ($exitCode -eq 0 -or $AllowFailure) {
            break
        }

        $isTransient = (
            $text -match 'ConnectionResetError|Connection aborted|timed out|Timeout|temporary failure|EOF occurred|SSL|TLS|502 Bad Gateway|503 Service Unavailable|429 Too Many Requests'
        )

        if (-not $isTransient -or $attempt -ge $MaxRetries) {
            break
        }

        Write-Host "Transient Azure CLI error (attempt $attempt/$MaxRetries). Retrying in $RetryDelaySeconds second(s)..." -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryDelaySeconds
    } while ($true)

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Azure CLI command failed (exit $exitCode): $cmdText`n$text"
    }

    if ($AsJson) {
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text | ConvertFrom-Json
    }

    return $text
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is not installed or not on PATH."
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  CREATE AVAILABILITY WEB TEST + ALERT" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Subscription:  $SubscriptionId"
Write-Host "  ResourceGroup: $ResourceGroup"
Write-Host "  App Insights:  $AppInsightsName"
Write-Host "  Web Test:      $WebTestName"
Write-Host "  Alert:         $AlertName"
Write-Host "  Action Group:  $ActionGroupName"
Write-Host ""

# Validate login/session and set subscription
Invoke-AzCli -Arguments @("account", "show", "--output", "none") | Out-Null
Invoke-AzCli -Arguments @("account", "set", "--subscription", $SubscriptionId) | Out-Null

$appInsightsResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/components/$AppInsightsName"
$actionGroupResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/actionGroups/$ActionGroupName"
$webTestResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Insights/webtests/$WebTestName"

# Validate target resources exist
Invoke-AzCli -Arguments @("resource", "show", "--ids", $appInsightsResourceId, "--output", "none") | Out-Null
Invoke-AzCli -Arguments @("monitor", "action-group", "show", "--ids", $actionGroupResourceId, "--output", "none") | Out-Null

$webTestXml = @"
<WebTest Name="$WebTestName" Id="$WebTestGuid" Enabled="True" CssProjectStructure="" CssIteration="" Timeout="$TimeoutSeconds" WorkItemIds="" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010" Description="$WebTestDescription" CredentialUserName="" CredentialPassword="" PreAuthenticate="True" Proxy="default" StopOnError="False" RecordedResultFile="" ResultsLocale="">
    <Items>
        <Request Method="GET" Guid="$RequestGuid" Version="1.1" Url="$WebTestUrl" ThinkTime="0" Timeout="$TimeoutSeconds" ParseDependentRequests="True" FollowRedirects="True" RecordResult="True" Cache="False" ResponseTimeGoal="0" Encoding="utf-8" ExpectedHttpStatusCode="200" ExpectedResponseUrl="" ReportingName="" IgnoreHttpStatusCode="False" />
    </Items>
</WebTest>
"@
$webTestXmlFile = Join-Path ([System.IO.Path]::GetTempPath()) ("webtest-xml-{0}.xml" -f ([Guid]::NewGuid().ToString("N")))
$webTestXml | Set-Content -Path $webTestXmlFile -Encoding utf8

$hiddenLinkTagKey = "hidden-link:$($appInsightsResourceId.ToLowerInvariant())"
$hiddenLinkTag = "$hiddenLinkTagKey=Resource"

Write-Host "Ensuring Azure CLI extension: application-insights..." -ForegroundColor Yellow
Invoke-AzCli -Arguments @(
    "config", "set",
    "extension.use_dynamic_install=yes_without_prompt",
    "extension.dynamic_install_allow_preview=true"
) -AllowFailure | Out-Null
Invoke-AzCli -Arguments @(
    "extension", "add",
    "--name", "application-insights",
    "--allow-preview", "true"
) -AllowFailure | Out-Null

Write-Host "Creating/updating availability web test..." -ForegroundColor Yellow
try {
    Invoke-AzCli -Arguments @(
        "monitor", "app-insights", "web-test", "create",
        "--subscription", $SubscriptionId,
        "--resource-group", $ResourceGroup,
        "--name", $WebTestName,
        "--kind", "ping",
        "--web-test-kind", "ping",
        "--location", $Location,
        "--web-test", "@$webTestXmlFile",
        "--description", $WebTestDescription,
        "--enabled", "true",
        "--frequency", "$FrequencySeconds",
        "--locations", "Id=$TestLocationId",
        "--defined-web-test-name", $WebTestName,
        "--retry-enabled", "true",
        "--synthetic-monitor-id", $WebTestName,
        "--timeout", "$TimeoutSeconds",
        "--tags", $hiddenLinkTag,
        "--output", "none"
    ) | Out-Null
} finally {
    Remove-Item -Path $webTestXmlFile -Force -ErrorAction SilentlyContinue
}

# (Optional) Replace existing alert for deterministic config
$alertExists = $false
Invoke-AzCli -Arguments @(
    "monitor", "metrics", "alert", "show",
    "--subscription", $SubscriptionId,
    "--resource-group", $ResourceGroup,
    "--name", $AlertName,
    "--output", "none"
) -AllowFailure | Out-Null
if ($LASTEXITCODE -eq 0) {
    $alertExists = $true
}

if ($alertExists) {
    Write-Host "Alert '$AlertName' exists. Deleting before recreate..." -ForegroundColor Yellow
    Invoke-AzCli -Arguments @(
        "monitor", "metrics", "alert", "delete",
        "--subscription", $SubscriptionId,
        "--resource-group", $ResourceGroup,
        "--name", $AlertName
    ) | Out-Null
    $alertExists = $false
}

$condition = "avg availabilityResults/availabilityPercentage < $AvailabilityPercentThreshold"

if (-not $alertExists) {
    Write-Host "Creating availability metric alert..." -ForegroundColor Yellow
    Invoke-AzCli -Arguments @(
        "monitor", "metrics", "alert", "create",
        "--subscription", $SubscriptionId,
        "--resource-group", $ResourceGroup,
        "--name", $AlertName,
        "--scopes", $appInsightsResourceId,
        "--condition", $condition,
        "--window-size", $WindowSize,
        "--evaluation-frequency", $EvaluationFrequency,
        "--action", $actionGroupResourceId,
        "--severity", "$Severity",
        "--description", $AlertDescription,
        "--output", "none"
    ) | Out-Null
}

# Verify action group webhook receivers (for visibility)
$webhookReceivers = Invoke-AzCli -Arguments @(
    "monitor", "action-group", "show",
    "--ids", $actionGroupResourceId,
    "--query", "webhookReceivers[].{name:name,uri:serviceUri}",
    "--output", "json"
) -AsJson

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  COMPLETE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Web Test ID:  $webTestResourceId"
Write-Host "  Alert Name:   $AlertName"
Write-Host "  Condition:    $condition"
Write-Host "  Action Group: $actionGroupResourceId"

if ($webhookReceivers -and $webhookReceivers.Count -gt 0) {
    Write-Host "  Webhook(s):" -ForegroundColor Green
    foreach ($receiver in $webhookReceivers) {
        Write-Host "    - $($receiver.name): $($receiver.uri)"
    }
} else {
    Write-Host "  ##[warning]Action Group has no webhook receivers configured. Alert is wired to the action group, but no webhook endpoint was found."
}

Write-Host ""
Write-Host "Done."
