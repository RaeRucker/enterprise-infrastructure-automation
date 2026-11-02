function Get-InfraOpsConfig {
    <#
    .SYNOPSIS
        Returns the active InfraOps configuration, optionally loading it from a .psd1 file.
    .DESCRIPTION
        Configuration is a PowerShell data file (no code execution). Values not present in
        the file fall back to safe defaults. See config/examples/InfraOps.config.psd1.
    .PARAMETER Path
        Path to a configuration .psd1 file. Loads and caches it for the session.
    .EXAMPLE
        Get-InfraOpsConfig -Path ./config/InfraOps.config.psd1
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string] $Path
    )

    $defaults = @{
        Logging    = @{ Path = $null }
        Thresholds = @{
            DiskWarningFreePercent  = 20
            DiskCriticalFreePercent = 10
            MemoryWarningPercent    = 85
            UptimeWarningDays       = 45
            PatchWarningDays        = 35
            StaleAccountDays        = 90
            CertificateWarningDays  = 30
            CertificateCriticalDays = 7
        }
        ServicesIgnoredWhenStopped = @(
            # Automatic services that legitimately stop after starting (trigger-start or delayed).
            'gupdate', 'gpsvc', 'MapsBroker', 'RemoteRegistry', 'sppsvc', 'edgeupdate', 'TrustedInstaller'
        )
        PrivilegedGroups = @(
            'Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators',
            'Account Operators', 'Backup Operators', 'Server Operators', 'Print Operators'
        )
    }

    if ($Path) {
        $loaded = Import-PowerShellDataFile -Path $Path
        foreach ($key in $loaded.Keys) {
            if ($defaults[$key] -is [hashtable] -and $loaded[$key] -is [hashtable]) {
                foreach ($sub in $loaded[$key].Keys) { $defaults[$key][$sub] = $loaded[$key][$sub] }
            } else {
                $defaults[$key] = $loaded[$key]
            }
        }
        $script:InfraOpsConfig = $defaults
    }

    if (-not $script:InfraOpsConfig) { $script:InfraOpsConfig = $defaults }
    return $script:InfraOpsConfig
}
