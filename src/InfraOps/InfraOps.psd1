@{
    RootModule           = 'InfraOps.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '3f6c2a8e-5d1b-4c7e-9a2f-8b4d6e1c0a73'
    Author               = 'Rae Rucker'
    Copyright            = '(c) 2026 Rae Rucker. MIT License.'
    Description          = 'Read-only-by-default infrastructure auditing and reporting for Windows Server, Active Directory, DNS, TLS certificates, Entra ID, and Azure.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')

    FunctionsToExport    = @(
        'Get-InfraOpsConfig'
        'Get-ServerHealth'
        'Get-StaleADAccount'
        'Disable-StaleADAccount'
        'Get-PrivilegedGroupMembership'
        'Get-RemoteSessionAudit'
        'Test-DnsConsistency'
        'Get-TlsCertificateExpiry'
        'Get-EntraGuestAccessReport'
        'Get-AzVmRetirementReport'
        'Export-InfraReport'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Infrastructure', 'Audit', 'ActiveDirectory', 'WindowsServer', 'Azure', 'EntraID')
            LicenseUri = 'https://github.com/RaeRucker/enterprise-infrastructure-automation/blob/main/LICENSE'
            ProjectUri = 'https://github.com/RaeRucker/enterprise-infrastructure-automation'
        }
    }
}
