<#
.SYNOPSIS
    Publishes the personal-pool maintenance runbook (spares + tidy-up) to its Automation account.

.DESCRIPTION
    The Bicep deployment (deployPoolAutomation = true) creates the Automation account, its
    managed identity and role assignments. This script, run automatically by Deploy-Avd.ps1
    after each deployment, publishes everything else:
      1. Template spec 'avd-sessionhost' (version 1.0) from infra/modules/sessionhost.bicep -
         the runbook deploys new desktops from it, so they match the main deployment
      2. Runbook 'AvdPoolMaintenance' from infra/automation/Invoke-AvdPoolMaintenance.ps1
      3. Variables: 'AvdPoolAutomationConfig' (settings from the deployment outputs) and
         'AvdLocalAdminPassword' (encrypted)
      4. A daily schedule (06:30 UTC) linked to the runbook
    It also writes <param file>.automation.json next to the parameter file for local
    report-only previews of the runbook.

    -RunNow starts one run immediately (in the configured mode).

.EXAMPLE
    .\scripts\Publish-AvdPoolAutomation.ps1 -ParameterFile .\infra\params\prod.bicepparam -RunNow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ParameterFile,
    [switch] $RunNow
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$runbookFile = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'automation') 'Invoke-AvdPoolMaintenance.ps1'
$sessionHostTemplate = Join-Path (Join-Path (Join-Path $repoRoot 'infra') 'modules') 'sessionhost.bicep'
$api = 'api-version=2023-11-01'
$runbookName = 'AvdPoolMaintenance'
$scheduleName = 'AvdPoolMaintenance-daily'

function Test-Az {
    $azArgs = $args
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @azArgs 2>$null
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = (($out | Out-String).Trim()) }
    }
    finally { $ErrorActionPreference = $eap }
}
function Invoke-AzRest([string] $Method, [string] $Url, $Body, [string] $ContentType = 'application/json') {
    $tmp = [IO.Path]::GetTempFileName()
    try {
        if ($Body -is [string]) { [IO.File]::WriteAllText($tmp, $Body, (New-Object System.Text.UTF8Encoding($false))) }
        elseif ($null -ne $Body) { [IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false))) }
        $r = if ($null -ne $Body) { Test-Az rest --method $Method --url $Url --headers "Content-Type=$ContentType" --body "@$tmp" --only-show-errors }
        else { Test-Az rest --method $Method --url $Url --only-show-errors }
        if (-not $r.Ok) { throw "$Method $Url failed." }
        return $r.Output
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Inputs
$ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
$paramText = Get-Content -Raw -LiteralPath $ParameterFile
if ($paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $null = Test-Az account set --subscription $Matches[1] --only-show-errors }
$base = [IO.Path]::GetFileNameWithoutExtension($ParameterFile)
$dir = Split-Path -Parent $ParameterFile
$outputsFile = Join-Path $dir "$base.outputs.json"
if (-not (Test-Path -LiteralPath $outputsFile)) { throw "No $outputsFile - run Deploy-Avd.ps1 first." }
$outs = Get-Content -Raw -LiteralPath $outputsFile | ConvertFrom-Json
$account = if ($outs.PSObject.Properties['automationAccountName']) { "$($outs.automationAccountName.value)" } else { '' }
if (-not $account) { throw "The deployment has no automation account. Set deployPoolAutomation = true (Personal host pools) and re-run Deploy-Avd.ps1." }
$rg = "$($outs.automationResourceGroup.value)"
$config = $outs.automationConfig.value
$sub = "$($config.subscriptionId)"
$acctId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Automation/automationAccounts/$account"
# 'az resource' rather than 'az automation' (an extension that may prompt to install itself).
$location = (Test-Az resource show --ids $acctId --query location -o tsv --only-show-errors).Output
if (-not $location) { $location = (Test-Az group show --name $rg --query location -o tsv --only-show-errors).Output }

$password = $env:AVD_LOCAL_ADMIN_PASSWORD
if (-not $password) {
    $secure = Read-Host -AsSecureString 'Session host local admin password (stored encrypted for new desktops)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

Write-Host "Automation account: $account ($rg), mode: $($config.mode)"

# ------------------------------------------------------------------ 1. Template spec
Write-Step 'Publishing the session host template spec (avd-sessionhost 1.0)'
$ts = Test-Az ts create --name avd-sessionhost --version 1.0 --resource-group $rg --location $location --template-file $sessionHostTemplate --description 'AVD session host (used by the pool maintenance runbook)' --yes --only-show-errors
if (-not $ts.Ok) { throw 'Creating the template spec failed (needs az CLI with Bicep).' }
$tsId = (Test-Az ts show --name avd-sessionhost --version 1.0 --resource-group $rg --query id -o tsv --only-show-errors).Output
if (-not $tsId) { throw 'Could not read the template spec ID.' }
$config | Add-Member -NotePropertyName templateSpecVersionId -NotePropertyValue $tsId -Force

# ------------------------------------------------------------------ 2. Runbook
Write-Step "Publishing runbook $runbookName"
$null = Invoke-AzRest PUT "https://management.azure.com$acctId/runbooks/$($runbookName)?$api" @{
    location = $location
    properties = @{ runbookType = 'PowerShell'; logVerbose = $false; logProgress = $false; description = 'Keeps spare personal desktops and removes long-unused ones (cm-lab-avd).' }
}
$null = Invoke-AzRest PUT "https://management.azure.com$acctId/runbooks/$runbookName/draft/content?$api" (Get-Content -Raw -LiteralPath $runbookFile) 'text/powershell'
$null = Invoke-AzRest POST "https://management.azure.com$acctId/runbooks/$runbookName/publish?$api" $null
for ($i = 0; $i -lt 12; $i++) {
    $state = (Test-Az rest --method get --url "https://management.azure.com$acctId/runbooks/$($runbookName)?$api" --query properties.state -o tsv --only-show-errors).Output
    if ($state -eq 'Published') { break }
    Start-Sleep -Seconds 5
}

# ------------------------------------------------------------------ 3. Variables
Write-Step 'Writing configuration variables'
$configJson = $config | ConvertTo-Json -Depth 30 -Compress
# Automation variable values are JSON-serialised: a string value is a quoted JSON string.
$null = Invoke-AzRest PUT "https://management.azure.com$acctId/variables/AvdPoolAutomationConfig?$api" @{
    name = 'AvdPoolAutomationConfig'
    properties = @{ value = ($configJson | ConvertTo-Json -Compress); isEncrypted = $false; description = 'Pool maintenance settings (from Deploy-Avd.ps1 outputs)' }
}
$null = Invoke-AzRest PUT "https://management.azure.com$acctId/variables/AvdLocalAdminPassword?$api" @{
    name = 'AvdLocalAdminPassword'
    properties = @{ value = ($password | ConvertTo-Json -Compress); isEncrypted = $true; description = 'Local admin password for new desktops' }
}
$localConfig = Join-Path $dir "$base.automation.json"
[IO.File]::WriteAllText($localConfig, ($config | ConvertTo-Json -Depth 30), (New-Object System.Text.UTF8Encoding($false)))

# ------------------------------------------------------------------ 4. Schedule
Write-Step 'Daily schedule (06:30 UTC)'
$sched = Test-Az rest --method get --url "https://management.azure.com$acctId/schedules/$($scheduleName)?$api" --only-show-errors
if (-not $sched.Ok) {
    $start = [datetime]::UtcNow.Date.AddDays(1).AddHours(6).AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $null = Invoke-AzRest PUT "https://management.azure.com$acctId/schedules/$($scheduleName)?$api" @{
        name = $scheduleName
        properties = @{ startTime = $start; frequency = 'Day'; interval = 1; timeZone = 'UTC'; description = 'Daily AVD pool maintenance' }
    }
}
$links = Test-Az rest --method get --url "https://management.azure.com$acctId/jobSchedules?$api" --query "value[?properties.runbook.name=='$runbookName' && properties.schedule.name=='$scheduleName'] | length(@)" -o tsv --only-show-errors
if (-not ($links.Ok -and [int]$links.Output -gt 0)) {
    $null = Invoke-AzRest PUT "https://management.azure.com$acctId/jobSchedules/$([guid]::NewGuid())?$api" @{
        properties = @{ schedule = @{ name = $scheduleName }; runbook = @{ name = $runbookName } }
    }
}

if ($RunNow) {
    Write-Step 'Starting a run now'
    $jobId = [guid]::NewGuid()
    $null = Invoke-AzRest PUT "https://management.azure.com$acctId/jobs/$($jobId)?$api" @{ properties = @{ runbook = @{ name = $runbookName } } }
    Write-Host "  Job $jobId started - see Automation account > Jobs for its output."
}

Write-Host ''
Write-Host ("Published. Mode: {0}. Runs daily at 06:30 UTC." -f $config.mode) -ForegroundColor Green
if ("$($config.mode)" -ne 'Apply') { Write-Host "  It only REPORTS until you set poolAutomationMode = 'Apply' and re-run Deploy-Avd.ps1 -InfraOnly." -ForegroundColor Yellow }
Write-Host "  Preview locally: .\infra\automation\Invoke-AvdPoolMaintenance.ps1 -ConfigPath $localConfig"
