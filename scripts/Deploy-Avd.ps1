<#
.SYNOPSIS
    Deploys (or previews) the AVD environment from Windows using the Azure CLI.

.DESCRIPTION
    PowerShell equivalent of scripts/deploy.sh. Works in Windows PowerShell 5.1 and PowerShell 7.

    * Reads the target subscription from the "// subscriptionId: <id>" header that
      New-AvdParameterFile.ps1 writes (or use -SubscriptionId).
    * Reads the region from "param location = '<region>'" in the parameter file.
    * Prompts for the session host local admin password (hidden) unless
      $env:AVD_LOCAL_ADMIN_PASSWORD is already set. The password is only placed in this
      process's environment for the duration of the run and removed afterwards.
    * Registers the required resource providers if they are not registered.
    * -WhatIf runs `az deployment sub what-if`; otherwise you are asked to confirm before
      `az deployment sub create` (skip with -Force).

    Requires the Azure CLI (winget install Microsoft.AzureCLI) and an `az login`.

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam -WhatIf

.EXAMPLE
    .\scripts\Deploy-Avd.ps1 -ParameterFile .\infra\params\prod.bicepparam
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ParameterFile,

    [string] $SubscriptionId,

    [string] $Location,

    [string] $DeploymentName = ('avd-' + (Get-Date -Format 'yyyyMMddHHmmss')),

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$preview = [bool]$WhatIfPreference
# Our own calls must not be suppressed by -WhatIf; we branch on $preview instead.
$WhatIfPreference = $false

$repoRoot = Split-Path -Parent $PSScriptRoot
$template = Join-Path (Join-Path $repoRoot 'infra') 'main.bicep'

function Invoke-Az {
    # Runs az with the given arguments, throws on failure, returns stdout text.
    $azArgs = $args
    $out = & az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az $($azArgs -join ' ') failed (exit code $LASTEXITCODE)." }
    return ($out -join "`n")
}

function Test-Az {
    # Runs az for a yes/no probe. Stderr is discarded; Windows PowerShell 5.1 would otherwise
    # turn redirected stderr into a terminating error under ErrorActionPreference = Stop.
    $azArgs = $args
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & az @azArgs 2>$null
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = (($out | Out-String).Trim()) }
    }
    finally { $ErrorActionPreference = $eap }
}

function Write-Step([string] $Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# ------------------------------------------------------------------ Checks
if (-not (Test-Path -LiteralPath $ParameterFile)) { throw "Parameter file not found: $ParameterFile" }
$ParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI not found. Install it with: winget install -e --id Microsoft.AzureCLI  (then open a new terminal)'
}

$paramText = Get-Content -Raw -LiteralPath $ParameterFile
if (-not $SubscriptionId -and $paramText -match '(?m)^//\s*subscriptionId:\s*([0-9a-fA-F-]{36})') { $SubscriptionId = $Matches[1] }
if (-not $SubscriptionId -and $env:AVD_SUBSCRIPTION_ID) { $SubscriptionId = $env:AVD_SUBSCRIPTION_ID }
if (-not $Location -and $paramText -match "(?m)^param\s+location\s*=\s*'([^']+)'") { $Location = $Matches[1] }
if (-not $Location) { $Location = 'uksouth' }

Write-Step 'Checking Azure CLI sign-in and Bicep'
if (-not (Test-Az account show --only-show-errors).Ok) {
    Write-Host 'Not signed in - opening az login.' -ForegroundColor Yellow
    $null = Invoke-Az login --only-show-errors
}
if (-not (Test-Az bicep version --only-show-errors).Ok) { $null = Invoke-Az bicep install --only-show-errors }

if ($SubscriptionId) { $null = Invoke-Az account set --subscription $SubscriptionId --only-show-errors }
$account = Invoke-Az account show --query '{name:name,id:id}' -o json --only-show-errors | ConvertFrom-Json

Write-Host ''
Write-Host ('  Subscription : {0} ({1})' -f $account.name, $account.id)
Write-Host ('  Region       : {0}' -f $Location)
Write-Host ('  Parameters   : {0}' -f $ParameterFile)
Write-Host ('  Mode         : {0}' -f $(if ($preview) { 'what-if (preview, no changes)' } else { 'CREATE / UPDATE' }))
Write-Host ''

# ------------------------------------------------------------------ Password
$setPassword = $false
if (-not $env:AVD_LOCAL_ADMIN_PASSWORD) {
    $secure = Read-Host -AsSecureString 'Session host local admin password (12+ chars, 3 of: upper, lower, digit, symbol)'
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $env:AVD_LOCAL_ADMIN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $setPassword = $true
    if ($env:AVD_LOCAL_ADMIN_PASSWORD.Length -lt 12) {
        Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD
        throw 'Password must be at least 12 characters (Azure requirement).'
    }
}

try {
    # -------------------------------------------------------------- Providers
    Write-Step 'Checking resource providers'
    foreach ($rp in 'Microsoft.DesktopVirtualization', 'Microsoft.Compute', 'Microsoft.Network',
        'Microsoft.Storage', 'Microsoft.OperationalInsights', 'Microsoft.Insights') {
        $state = (Test-Az provider show --namespace $rp --query registrationState -o tsv --only-show-errors).Output
        if ($state -ne 'Registered') {
            Write-Host "  registering $rp"
            $null = Invoke-Az provider register --namespace $rp --only-show-errors
        }
    }

    $common = @('--name', $DeploymentName, '--location', $Location,
        '--template-file', $template, '--parameters', $ParameterFile, '--only-show-errors')

    if ($preview) {
        Write-Step 'Running what-if (no changes will be made)'
        & az deployment sub what-if @common
        if ($LASTEXITCODE -ne 0) { throw 'what-if failed - see the error above.' }
        Write-Host ''
        Write-Host 'Preview complete. Run again without -WhatIf to deploy.' -ForegroundColor Green
        return
    }

    if (-not $Force) {
        $answer = Read-Host "Deploy to '$($account.name)'? Type yes to continue"
        if ($answer -ne 'yes') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
    }

    Write-Step "Deploying ($DeploymentName) - a full 100-host run takes roughly 45-90 minutes"
    $result = & az deployment sub create @common --query 'properties.outputs' -o json
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment failed. Details: az deployment sub show --name $DeploymentName  (or the subscription's Deployments blade in the portal)."
    }

    $outputs = ($result -join "`n") | ConvertFrom-Json
    Write-Host ''
    Write-Host 'Deployment succeeded.' -ForegroundColor Green
    foreach ($p in $outputs.PSObject.Properties) {
        $v = $p.Value.value
        if ($v -is [array]) { $v = $v -join ', ' }
        Write-Host ('  {0,-28} {1}' -f $p.Name, $v)
    }
    Write-Host ''
    Write-Host 'Next: the post-deployment steps in README.md (storage admin consent, CA exclusion, NTFS permissions).'
}
finally {
    if ($setPassword) { Remove-Item Env:\AVD_LOCAL_ADMIN_PASSWORD -ErrorAction SilentlyContinue }
}
