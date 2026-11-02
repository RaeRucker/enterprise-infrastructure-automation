<#
.SYNOPSIS
    Scheduled operational check: server health, TLS expiry, and DNS consistency in one HTML/CSV report set.
.DESCRIPTION
    Intended to run daily as a scheduled task under a least-privilege service account
    (a group Managed Service Account is recommended, so there's no password to store).

    Exit codes (for the scheduler or a monitoring system):
      0  everything healthy
      1  at least one Warning
      2  at least one Critical / Unreachable / failed check
.EXAMPLE
    ./scripts/Invoke-DailyInfraCheck.ps1 -ConfigPath ./config/InfraOps.config.psd1
.EXAMPLE
    # Register as a daily task running as a gMSA (run once, elevated)
    $action  = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\InfraOps\scripts\Invoke-DailyInfraCheck.ps1 -ConfigPath C:\InfraOps\config\InfraOps.config.psd1'
    $trigger = New-ScheduledTaskTrigger -Daily -At 6am
    $principal = New-ScheduledTaskPrincipal -UserId 'CORP\gmsa-infraops$' -LogonType Password
    Register-ScheduledTask -TaskName 'InfraOps Daily Check' -Action $action -Trigger $trigger -Principal $principal
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../src/InfraOps/InfraOps.psd1') -Force
$config = Get-InfraOpsConfig -Path $ConfigPath
$daily = $config.DailyCheck

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out = $daily.OutputFolder
New-Item -ItemType Directory -Path $out -Force | Out-Null

$servers = @(Get-Content -Path $daily.ServerListPath | Where-Object { $_ -and $_ -notmatch '^\s*#' })
$health = @($servers | Get-ServerHealth)
$tls = @($daily.TlsEndpoints | Get-TlsCertificateExpiry)
$dns = @(Test-DnsConsistency -Name $daily.DnsNames -Server $daily.DnsServers)

$health | Export-InfraReport -Path (Join-Path $out "server-health-$stamp.html") -Title 'Server health'
$health | Export-InfraReport -Path (Join-Path $out "server-health-$stamp.csv")
$tls    | Export-InfraReport -Path (Join-Path $out "tls-certificates-$stamp.html") -Title 'TLS certificates'
$dns    | Export-InfraReport -Path (Join-Path $out "dns-consistency-$stamp.html") -Title 'DNS consistency'

# Retention: keep the newest N reports of each kind.
Get-ChildItem -Path $out -File | Group-Object { $_.Name -replace '-\d{8}-\d{4}', '' } | ForEach-Object {
    $_.Group | Sort-Object LastWriteTime -Descending | Select-Object -Skip $daily.RetainReports | Remove-Item -Force
}

$critical = @($health | Where-Object Status -In 'Critical', 'Unreachable').Count +
            @($tls | Where-Object Status -In 'Critical', 'Unreachable', 'NameMismatch', 'Untrusted').Count +
            @($dns | Where-Object { -not $_.Consistent }).Count
$warning  = @($health | Where-Object Status -EQ 'Warning').Count + @($tls | Where-Object Status -EQ 'Warning').Count

Write-Output ("Servers: {0}  TLS endpoints: {1}  DNS names: {2}  Critical: {3}  Warning: {4}" -f $health.Count, $tls.Count, $dns.Count, $critical, $warning)
if ($critical) { exit 2 } elseif ($warning) { exit 1 } else { exit 0 }
