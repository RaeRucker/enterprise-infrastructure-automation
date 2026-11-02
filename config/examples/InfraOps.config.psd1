# Example configuration. Copy to config/InfraOps.config.psd1 (git-ignored) and edit.
# This is a PowerShell data file: it's parsed, never executed.
@{
    Logging = @{
        # JSON Lines audit log. Point a Log Analytics agent or SIEM collector at this path.
        Path = 'C:\ProgramData\InfraOps\logs\infraops.log'
    }

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

    # Automatic services that legitimately stop after starting (trigger-start or delayed).
    ServicesIgnoredWhenStopped = @('gupdate', 'gpsvc', 'MapsBroker', 'RemoteRegistry', 'sppsvc', 'edgeupdate', 'TrustedInstaller')

    PrivilegedGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators', 'Account Operators', 'Backup Operators', 'Server Operators')

    # Used by scripts/Invoke-DailyInfraCheck.ps1
    DailyCheck = @{
        ServerListPath = 'C:\ProgramData\InfraOps\servers.txt'
        TlsEndpoints   = @('portal.example.com', 'dc01.corp.example:636')
        DnsServers     = @('10.0.0.4', '10.0.0.5')
        DnsNames       = @('portal.corp.example', 'sql01.corp.example')
        OutputFolder   = 'C:\ProgramData\InfraOps\reports'
        RetainReports  = 30
    }
}
