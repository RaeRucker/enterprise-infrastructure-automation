<#
.SYNOPSIS
    Regenerates the example reports in examples/output from a synthetic environment.
.DESCRIPTION
    Replaces the module's private data-access wrappers (CIM, AD, quser, TLS) with
    synthetic data, then runs the real public functions and Export-InfraReport. The
    output is produced by the same code paths a real run uses; only the data source
    is fictional. No network access or credentials are required.
#>
[CmdletBinding()]
param([string] $OutputFolder = (Join-Path $PSScriptRoot 'output'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/InfraOps/InfraOps.psd1') -Force
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

& (Get-Module InfraOps) {
    param($out, $fixtures)

    # ---- Synthetic environment: 5 servers ----
    $script:fake = @{
        'SRV-APP01' = @{ Boot = -6;  FreeMem = 6;  Disks = @(,@('C:', 128, 71));            Stopped = @();        Reboot = @();                 Patch = -9 }
        'SRV-APP02' = @{ Boot = -61; FreeMem = 5;  Disks = @(,@('C:', 128, 64));            Stopped = @('W3SVC'); Reboot = @('Windows Update'); Patch = -9 }
        'SRV-SQL01' = @{ Boot = -12; FreeMem = 1;  Disks = @(@('C:', 128, 40), @('E:', 512, 31)); Stopped = @(); Reboot = @();                 Patch = -9 }
        'SRV-FS01'  = @{ Boot = -20; FreeMem = 9;  Disks = @(@('C:', 128, 50), @('D:', 2048, 102)); Stopped = @(); Reboot = @();               Patch = -48 }
    }
    function Open-InfraCimSession { param($ComputerName, [pscredential] $Credential) if ($ComputerName -eq 'SRV-LEGACY03') { throw 'WinRM cannot complete the operation. Verify that the specified computer name is valid.' }; [pscustomobject]@{ ComputerName = $ComputerName } }
    function Close-InfraCimSession { param($CimSession) }
    function Test-InfraPendingReboot { param($CimSession) $script:fake[$CimSession.ComputerName].Reboot }
    function Invoke-InfraCimQuery {
        param($CimSession, $ClassName, $Filter)
        $f = $script:fake[$CimSession.ComputerName]
        switch ($ClassName) {
            'Win32_OperatingSystem'     { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddDays($f.Boot); FreePhysicalMemory = $f.FreeMem * 1MB; TotalVisibleMemorySize = 16MB } }
            'Win32_LogicalDisk'         { foreach ($d in $f.Disks) { [pscustomobject]@{ DeviceID = $d[0]; Size = $d[1] * 1GB; FreeSpace = $d[2] * 1GB } } }
            'Win32_Service'             { foreach ($s in $f.Stopped) { [pscustomobject]@{ Name = $s } } }
            'Win32_QuickFixEngineering' { [pscustomobject]@{ HotFixID = 'KB5000000'; InstalledOn = (Get-Date).AddDays($f.Patch) } }
        }
    }
    'SRV-APP01', 'SRV-APP02', 'SRV-SQL01', 'SRV-FS01', 'SRV-LEGACY03' |
        Get-ServerHealth -WarningAction SilentlyContinue |
        Export-InfraReport -Path (Join-Path $out 'server-health.html') -Title 'Server health (synthetic environment)'

    # ---- Remote sessions from the quser fixture ----
    function Invoke-InfraQuser { param($ComputerName) Get-Content (Join-Path $fixtures 'quser-output.txt') }
    Get-RemoteSessionAudit -ComputerName 'SRV-RDS01' |
        Select-Object ComputerName, UserName, SessionName, Id, State, IdleHours, LogonTime, Flagged |
        Export-InfraReport -Path (Join-Path $out 'remote-sessions.csv')

    # ---- TLS endpoints ----
    $script:certs = @{
        'portal.example.com'   = @(210, 'None')
        'api.example.com'      = @(18,  'None')
        'legacy.example.com'   = @(4,   'None')
        'intranet.corp.example' = @(160, 'RemoteCertificateNameMismatch')
    }
    function Get-InfraRemoteCertificate {
        param($HostName, $Port, $TimeoutSeconds)
        $c = $script:certs[$HostName]
        [pscustomobject]@{ Subject = "CN=$HostName"; Issuer = 'CN=Example Issuing CA 01'; NotAfter = (Get-Date).AddDays($c[0]).AddHours(2); Thumbprint = ('{0:X40}' -f $HostName.GetHashCode()).Substring(0, 40); PolicyErrors = $c[1] }
    }
    $script:certs.Keys | Sort-Object | Get-TlsCertificateExpiry |
        Export-InfraReport -Path (Join-Path $out 'tls-certificates.html') -Title 'TLS certificate expiry (synthetic environment)'
} $OutputFolder (Join-Path $PSScriptRoot '../tests/fixtures')

Get-ChildItem $OutputFolder | Select-Object Name, Length
