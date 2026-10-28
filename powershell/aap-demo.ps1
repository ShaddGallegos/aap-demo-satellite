#Requires -Version 5.1

<#

.SYNOPSIS

  aap-demo CLI for Windows (PowerShell).



.DESCRIPTION

  All commands run natively in PowerShell.

#>

[CmdletBinding()]

param(

  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]

  [string[]]$Arguments

)



Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'



$ModuleRoot = Join-Path $PSScriptRoot 'native'

Import-Module (Join-Path $ModuleRoot 'AapDemo.psm1') -Force



function Get-AapParsedCliArgs {

  param([string[]]$Rest)



  $parsed = @{

    Namespace    = $null

    Channel      = $null

    OcpVersion   = $null

    CrName       = 'minimal'

    PublicUrl    = $null

    Force        = $false

    Reset        = $false

    Ai           = $false
    Apply        = $false
    FullDemo     = $false
    ShowSecrets  = $false
    NoOpen       = $false
    Json         = $false

    Positional   = [System.Collections.Generic.List[string]]::new()

  }



  foreach ($arg in @($Rest)) {

    switch -Regex ($arg) {

      '^-Force$|^--force$' { $parsed.Force = $true; continue }

      '^--reset$' { $parsed.Reset = $true; continue }

      '^--ai$' { $parsed.Ai = $true; continue }
      '^--apply$' { $parsed.Apply = $true; continue }
      '^--full-demo$' { $parsed.FullDemo = $true; continue }
      '^--show-secrets$' { $parsed.ShowSecrets = $true; continue }
      '^--no-open$' { $parsed.NoOpen = $true; continue }
      '^--json$' { $parsed.Json = $true; continue }

      '^-Namespace=(.+)$' { $parsed.Namespace = $Matches[1]; continue }

      '^-Channel=(.+)$' { $parsed.Channel = $Matches[1]; continue }

      '^-OcpVersion=(.+)$' { $parsed.OcpVersion = $Matches[1]; continue }

      '^CR=(.+)$' { $parsed.CrName = $Matches[1]; continue }

      '^PUBLIC_URL=(.+)$' { $parsed.PublicUrl = $Matches[1]; continue }

      '^NAMESPACE=(.+)$' { $parsed.Namespace = $Matches[1]; continue }

      '^AAP_OCP_VERSION=(.+)$' { $parsed.OcpVersion = $Matches[1]; continue }

      default { $parsed.Positional.Add($arg) | Out-Null }

    }

  }

  return $parsed

}



function Invoke-AapDeployParams {

  param($Parsed)



  $params = @{}

  if ($Parsed.Namespace) { $params.Namespace = $Parsed.Namespace }

  if ($Parsed.Channel) { $params.Channel = $Parsed.Channel }

  if ($Parsed.OcpVersion) { $params.OcpVersion = $Parsed.OcpVersion }

  if ($Parsed.CrName) { $params.CrName = $Parsed.CrName }

  if ($Parsed.Force) { $params.Force = $true }

  return $params

}



if (-not $Arguments -or $Arguments.Count -eq 0) {

  Get-AapDemoHelp

  exit 0

}



$command = $Arguments[0].ToLowerInvariant()

$rest = @()

if ($Arguments.Count -gt 1) {

  $rest = $Arguments[1..($Arguments.Count - 1)]

}

$cli = Get-AapParsedCliArgs -Rest $rest

$lockedCommands = @('repair', 'clean', 'maintenance', 'destroy', 'stop', 'start', 'restart', 'create', 'setup', 'update', 'config', 'redeploy', 'redeploy-all', 'kubeconfig', 'idle', 'enable', 'disable', 'deploy', 'deploy-all', 'setup-pah')

# login-start takes the lock itself so lock failures are recorded in last-login.json.

$unlockedServiceCommands = @('status', 'backups', 'verify', 'login-start')

$lockToken = $null

try {

  if ($cli.Json -or $env:AAP_DEMO_DASHBOARD_COMMAND -eq '1') {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  }
  if ($cli.FullDemo -and $command -ne 'create') {
    throw '--full-demo is supported only by create'
  }
  if ($cli.NoOpen -and $command -ne 'dashboard') {
    throw '--no-open is supported only by dashboard'
  }
  if ($cli.Json -and ($command -ne 'status' -or $cli.ShowSecrets)) {
    throw '--json is supported only by status without --show-secrets'
  }
  if ($cli.ShowSecrets -and $command -ne 'status') {
    throw '--show-secrets is supported only by status'
  }
  if ($cli.ShowSecrets -and [Console]::IsOutputRedirected) {
    throw '--show-secrets requires an interactive terminal'
  }

  if ($command -in @('create', 'destroy', 'redeploy-all')) {

    Assert-AapStateNotManaged -Operation $command

  }

  $serviceSub = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { 'status' }

  if ($command -in $lockedCommands -or ($command -eq 'service' -and $serviceSub -notin $unlockedServiceCommands)) {

    $lockToken = Enter-AapOperationLock -Command $command

  }

  switch ($command) {

    'create' {
      if ($cli.FullDemo) {
        throw 'create --full-demo requires the Bash/Linux CLI because Fleet VM management is not available in native PowerShell.'
      }
      Invoke-AapDemoCreate
      Initialize-AapDemoRecovery
    }

    'deploy' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoDeploy @deployParams
    }

    'deploy-all' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoDeploy @deployParams
    }

    'status' {
      if ($cli.Json) {
        Get-AapDemoDashboardInventory | ConvertTo-Json -Depth 20 -Compress
      } else {
        Invoke-AapDemoStatus -ShowSecrets:$cli.ShowSecrets
      }
    }

    'dashboard' { Invoke-AapDemoDashboard -NoOpen:$cli.NoOpen }

    'version' { Invoke-AapDemoVersion }

    '--version' { Invoke-AapDemoVersion }

    '-v' { Invoke-AapDemoVersion }

    'diagnose' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      if ($cli.Ai) { $params.Ai = $true }

      Invoke-AapDemoDiagnose @params

    }

    'watch' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      Invoke-AapDemoWatch @params

    }

    'start' { Invoke-AapDemoStartCommand }

    'restart' { Invoke-AapDemoRestart }

    'stop' { Invoke-AapDemoStopCommand }

    'service' {

      $serviceArgs = @($cli.Positional)

      if ($cli.Apply) { $serviceArgs += '--apply' }

      if ($cli.Force) { $serviceArgs += '--force' }

      Invoke-AapDemoService -Arguments $serviceArgs

    }

    'destroy' { Invoke-AapDemoDestroy -Reset:$cli.Reset }

    'clean' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      Invoke-AapDemoClean @params

    }

    'maintenance' {
      $uninstall = $cli.Positional.Count -gt 0 -and $cli.Positional[0] -eq 'uninstall'
      Invoke-AapDemoMaintenance -Apply:$cli.Apply -Uninstall:$uninstall
    }

    'repair' { Invoke-AapDemoRepair }

    'setup' { Invoke-AapDemoSetup }

    'setup-pah' {
      $params = @{}
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoSetupPah @params
    }

    'ssh' { Invoke-AapDemoSsh }

    'kubeconfig' { Invoke-AapDemoKubeconfig }

    'idle' {

      $params = @{}

      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }

      if ($cli.Positional.Count -gt 0) { $params.Value = $cli.Positional[0] }

      Invoke-AapDemoIdle @params

    }

    'config' {

      $key = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $val = if ($cli.Positional.Count -gt 1) { $cli.Positional[1] } else { $null }

      Invoke-AapDemoConfig -Key $key -Value $val

    }

    'update' { Invoke-AapDemoUpdate }

    'redhat-status' { Invoke-AapDemoRedhatStatus }

    'rh-status' { Invoke-AapDemoRedhatStatus }

    'must-gather' {

      $dest = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      Invoke-AapDemoMustGather -DestDir $dest

    }

    'enable' {

      $addon = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $params = @{}
      if ($addon) { $params.Addon = $addon }
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoEnable @params

    }

    'disable' {

      $addon = if ($cli.Positional.Count -gt 0) { $cli.Positional[0] } else { $null }

      $params = @{}
      if ($addon) { $params.Addon = $addon }
      if ($cli.Namespace) { $params.Namespace = $cli.Namespace }
      Invoke-AapDemoDisable @params

    }

    'redeploy' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoRedeploy @deployParams
    }

    'redeploy-all' {
      $deployParams = Invoke-AapDeployParams $cli
      Invoke-AapDemoRedeployAll @deployParams
    }

    { $_ -in @('help', '--help', '-h') } { Get-AapDemoHelp }

    default {

      Write-Host "Unknown command: $($Arguments[0])"

      Write-Host "Run 'aap-demo help' for usage"

      exit 1

    }

  }

} catch {

  Write-Host "  ERROR $($_.Exception.Message)" -ForegroundColor Red

  Exit-AapOperationLock -Token $lockToken

  $lockToken = $null

  exit 1

} finally {

  Exit-AapOperationLock -Token $lockToken

}

if ($command -in @('create', 'start', 'restart')) {
  Invoke-AapDemoAutoDashboard
}
