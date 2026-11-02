#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Unit tests for the InfraOps module. Every external system (CIM/WinRM, Active
    Directory, DNS, Microsoft Graph, Azure Resource Graph, TLS endpoints) is mocked
    with synthetic data, so the suite runs on any OS without network access or
    credentials. All names, addresses, and accounts below are fictional.
#>

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/InfraOps/InfraOps.psd1') -Force
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
}

AfterAll { Remove-Module InfraOps -ErrorAction SilentlyContinue }

Describe 'Module' {
    It 'has a valid manifest' {
        { Test-ModuleManifest (Join-Path $script:root 'src/InfraOps/InfraOps.psd1') -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports only the declared public functions' {
        $exported = (Get-Module InfraOps).ExportedFunctions.Keys | Sort-Object
        $exported | Should -Contain 'Get-ServerHealth'
        $exported | Should -Not -Contain 'Write-InfraLog'
        $exported | Should -Not -Contain 'Invoke-InfraCimQuery'
        $exported.Count | Should -Be 11
    }

    It '<_> has a synopsis, a description, and at least one example' -ForEach @(
        (Import-PowerShellDataFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/InfraOps/InfraOps.psd1')).FunctionsToExport
    ) {
        $help = Get-Help $_ -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Description | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }

    It 'requires confirmation for destructive commands' {
        $meta = [System.Management.Automation.CommandMetadata]::new((Get-Command Disable-StaleADAccount))
        $meta.SupportsShouldProcess | Should -BeTrue
        $meta.ConfirmImpact | Should -Be 'High'
    }
}

Describe 'Get-InfraOpsConfig' {
    It 'returns safe defaults without a file' {
        $c = Get-InfraOpsConfig
        $c.Thresholds.StaleAccountDays | Should -Be 90
        $c.Logging.Path | Should -BeNullOrEmpty
    }

    It 'merges a configuration file over the defaults' {
        $file = Join-Path $TestDrive 'cfg.psd1'
        "@{ Thresholds = @{ StaleAccountDays = 60 } }" | Set-Content $file
        $c = Get-InfraOpsConfig -Path $file
        $c.Thresholds.StaleAccountDays | Should -Be 60
        $c.Thresholds.DiskWarningFreePercent | Should -Be 20   # untouched default
    }

    AfterAll {
        InModuleScope InfraOps { $script:InfraOpsConfig = $null }
    }
}

Describe 'Get-ServerHealth' {
    BeforeAll {
        Mock -ModuleName InfraOps Open-InfraCimSession { [pscustomobject]@{ ComputerName = $ComputerName } }
        Mock -ModuleName InfraOps Close-InfraCimSession { }
        Mock -ModuleName InfraOps Test-InfraPendingReboot { @() }
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' } {
            [pscustomobject]@{ LastBootUpTime = (Get-Date).AddDays(-3); FreePhysicalMemory = 4GB / 1KB; TotalVisibleMemorySize = 16GB / 1KB }
        }
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' } {
            [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 60GB }
        }
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_Service' } { }
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_QuickFixEngineering' } {
            [pscustomobject]@{ HotFixID = 'KB5000001'; InstalledOn = (Get-Date).AddDays(-10) }
        }
    }

    It 'reports Healthy when every metric is within thresholds' {
        $r = Get-ServerHealth -ComputerName 'SRV-APP01'
        $r.Status | Should -Be 'Healthy'
        $r.Findings | Should -BeNullOrEmpty
        $r.MemoryUsedPercent | Should -Be 75
        $r.PSObject.TypeNames[0] | Should -Be 'InfraOps.ServerHealth'
    }

    It 'reports Critical when a disk is below the critical threshold' {
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_LogicalDisk' } {
            [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 6GB }
            [pscustomobject]@{ DeviceID = 'D:'; Size = 500GB; FreeSpace = 80GB }
        }
        $r = Get-ServerHealth -ComputerName 'SRV-SQL01'
        $r.Status | Should -Be 'Critical'
        $r.Findings | Should -Contain 'Disk C: 6% free (<= 10%)'
        $r.Findings | Should -Contain 'Disk D: 16% free (<= 20%)'
    }

    It 'reports Warning for stopped automatic services, ignoring known trigger-start services' {
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_Service' } {
            [pscustomobject]@{ Name = 'W3SVC' }
            [pscustomobject]@{ Name = 'gupdate' }
        }
        $r = Get-ServerHealth -ComputerName 'SRV-WEB01'
        $r.Status | Should -Be 'Warning'
        $r.StoppedAutoServices | Should -Be @('W3SVC')
    }

    It 'reports a pending reboot and missing recent updates' {
        Mock -ModuleName InfraOps Test-InfraPendingReboot { @('Windows Update') }
        Mock -ModuleName InfraOps Invoke-InfraCimQuery -ParameterFilter { $ClassName -eq 'Win32_QuickFixEngineering' } {
            [pscustomobject]@{ HotFixID = 'KB4000001'; InstalledOn = (Get-Date).AddDays(-90) }
        }
        $r = Get-ServerHealth -ComputerName 'SRV-FS01'
        $r.Status | Should -Be 'Warning'
        $r.Findings | Should -Contain 'Reboot pending: Windows Update'
        $r.Findings | Should -Contain 'No update installed in the last 35 days'
    }

    It 'returns Unreachable for a host that fails, and continues with the rest' {
        Mock -ModuleName InfraOps Open-InfraCimSession -ParameterFilter { $ComputerName -eq 'SRV-DOWN01' } { throw 'WinRM cannot complete the operation' }
        $r = @('SRV-DOWN01', 'SRV-APP01' | Get-ServerHealth -WarningAction SilentlyContinue)
        $r.Count | Should -Be 2
        $r[0].Status | Should -Be 'Unreachable'
        $r[0].Findings[0] | Should -Match 'WinRM'
        $r[1].Status | Should -Be 'Healthy'
    }

    It 'always closes the CIM session' {
        Get-ServerHealth -ComputerName 'SRV-APP01' | Out-Null
        Should -Invoke -ModuleName InfraOps Close-InfraCimSession -Times 1 -Exactly -Scope It
    }
}

Describe 'Get-StaleADAccount' {
    BeforeAll {
        $now = (Get-Date).ToUniversalTime()
        Mock -ModuleName InfraOps Get-InfraADAccount {
            [pscustomobject]@{ Name = 'Active User';   SamAccountName = 'a.user';   Enabled = $true;  whenCreated = $now.AddYears(-2); lastLogonTimestamp = $now.AddDays(-5).ToFileTimeUtc();   PasswordNeverExpires = $false; DistinguishedName = 'CN=a.user,OU=Staff,DC=corp,DC=example' }
            [pscustomobject]@{ Name = 'Stale User';    SamAccountName = 's.user';   Enabled = $true;  whenCreated = $now.AddYears(-2); lastLogonTimestamp = $now.AddDays(-200).ToFileTimeUtc(); PasswordNeverExpires = $false; DistinguishedName = 'CN=s.user,OU=Staff,DC=corp,DC=example' }
            [pscustomobject]@{ Name = 'Never Used';    SamAccountName = 'n.user';   Enabled = $true;  whenCreated = $now.AddYears(-1); lastLogonTimestamp = $null;                              PasswordNeverExpires = $false; DistinguishedName = 'CN=n.user,OU=Staff,DC=corp,DC=example' }
            [pscustomobject]@{ Name = 'New Hire';      SamAccountName = 'new.user'; Enabled = $true;  whenCreated = $now.AddDays(-10); lastLogonTimestamp = $null;                              PasswordNeverExpires = $false; DistinguishedName = 'CN=new.user,OU=Staff,DC=corp,DC=example' }
            [pscustomobject]@{ Name = 'Already Off';   SamAccountName = 'off.user'; Enabled = $false; whenCreated = $now.AddYears(-3); lastLogonTimestamp = $now.AddDays(-400).ToFileTimeUtc(); PasswordNeverExpires = $false; DistinguishedName = 'CN=off.user,OU=Staff,DC=corp,DC=example' }
            [pscustomobject]@{ Name = 'svc-backup';    SamAccountName = 'svc-backup'; Enabled = $true; whenCreated = $now.AddYears(-4); lastLogonTimestamp = $now.AddDays(-150).ToFileTimeUtc(); PasswordNeverExpires = $true; DistinguishedName = 'CN=svc-backup,OU=Service,DC=corp,DC=example' }
        }
    }

    It 'returns enabled accounts inactive beyond the threshold, including never-used ones' {
        $r = Get-StaleADAccount -Type User -InactiveDays 90
        $r.SamAccountName | Should -Be @('n.user', 's.user', 'svc-backup')
    }

    It 'excludes new accounts, disabled accounts, and recently active accounts' {
        $names = (Get-StaleADAccount -Type User -InactiveDays 90).SamAccountName
        $names | Should -Not -Contain 'new.user'
        $names | Should -Not -Contain 'off.user'
        $names | Should -Not -Contain 'a.user'
    }

    It 'flags non-expiring passwords as likely service accounts' {
        $svc = Get-StaleADAccount -Type User | Where-Object SamAccountName -EQ 'svc-backup'
        $svc.Recommendation | Should -Match 'service account'
    }

    It 'rejects an inactivity window shorter than the lastLogonTimestamp replication interval' {
        { Get-StaleADAccount -Type User -InactiveDays 7 } | Should -Throw
    }
}

Describe 'Disable-StaleADAccount' {
    BeforeAll {
        Mock -ModuleName InfraOps Disable-InfraADAccount { }
        function New-Stale([string] $sam, [bool] $nonExpiring = $false) {
            [pscustomobject]@{
                PSTypeName = 'InfraOps.StaleAccount'; SamAccountName = $sam; DaysInactive = 200; NeverLoggedOn = $false
                PasswordNeverExpires = $nonExpiring; DistinguishedName = "CN=$sam,OU=Staff,DC=corp,DC=example"
            }
        }
    }

    It 'changes nothing with -WhatIf' {
        New-Stale 's.user' | Disable-StaleADAccount -WhatIf
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 0 -Scope It
    }

    It 'disables, records who and why, and moves to the quarantine OU' {
        $r = New-Stale 's.user' | Disable-StaleADAccount -QuarantineOU 'OU=Disabled,DC=corp,DC=example' -Confirm:$false
        $r.Action | Should -Be 'Disabled'
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 1 -Exactly -Scope It -ParameterFilter {
            $TargetPath -eq 'OU=Disabled,DC=corp,DC=example' -and $Description -match '^Disabled by InfraOps \d{4}-\d{2}-\d{2} .+: inactive 200 days$'
        }
    }

    It 'skips accounts with non-expiring passwords unless explicitly included' {
        New-Stale 'svc-backup' $true | Disable-StaleADAccount -Confirm:$false -WarningAction SilentlyContinue
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 0 -Scope It
        New-Stale 'svc-backup' $true | Disable-StaleADAccount -IncludeNonExpiringPasswords -Confirm:$false
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 1 -Scope It
    }

    It 'stops at MaxCount' {
        1..5 | ForEach-Object { New-Stale "u$_" } | Disable-StaleADAccount -MaxCount 2 -Confirm:$false -WarningAction SilentlyContinue
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 2 -Exactly -Scope It
    }

    It 'only accepts objects produced by Get-StaleADAccount' {
        # Pipeline binding errors are non-terminating; -ErrorAction Stop surfaces them.
        { [pscustomobject]@{ SamAccountName = 'x' } | Disable-StaleADAccount -Confirm:$false -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName InfraOps Disable-InfraADAccount -Times 0 -Scope It
    }
}

Describe 'Get-PrivilegedGroupMembership' {
    It 'flags non-expiring, old, stale, and disabled members' {
        $now = (Get-Date).ToUniversalTime()
        Mock -ModuleName InfraOps Get-InfraADGroupMember {
            [pscustomobject]@{ SamAccountName = 'adm.ok';    Name = 'OK';    Enabled = $true;  PasswordNeverExpires = $false; PasswordLastSet = $now.AddDays(-30);  lastLogonTimestamp = $now.AddDays(-1).ToFileTimeUtc() }
            [pscustomobject]@{ SamAccountName = 'adm.risky'; Name = 'Risky'; Enabled = $true;  PasswordNeverExpires = $true;  PasswordLastSet = $now.AddDays(-800); lastLogonTimestamp = $now.AddDays(-300).ToFileTimeUtc() }
            [pscustomobject]@{ SamAccountName = 'adm.gone';  Name = 'Gone';  Enabled = $false; PasswordNeverExpires = $false; PasswordLastSet = $now.AddDays(-100); lastLogonTimestamp = $null }
        }
        $r = Get-PrivilegedGroupMembership -Group 'Domain Admins'
        ($r | Where-Object SamAccountName -EQ 'adm.ok').Flags | Should -BeNullOrEmpty
        ($r | Where-Object SamAccountName -EQ 'adm.risky').Flags | Should -Be @('PasswordNeverExpires', 'PasswordOlderThan1Year', 'Stale')
        ($r | Where-Object SamAccountName -EQ 'adm.gone').Flags | Should -Be @('DisabledButMember')
    }
}

Describe 'Remote session parsing' {
    BeforeAll {
        $lines = Get-Content (Join-Path $script:fixtures 'quser-output.txt')
        $sessions = InModuleScope InfraOps -Parameters @{ l = $lines } { param($l) ConvertFrom-InfraQuserOutput -Line $l -ComputerName 'SRV-RDS01' }
    }

    It 'parses every session row' { $sessions.Count | Should -Be 4 }

    It 'handles a blank SESSIONNAME column for disconnected sessions' {
        $disc = $sessions | Where-Object UserName -EQ 'j.alvarez'
        $disc.SessionName | Should -Be ''
        $disc.Id | Should -Be 3
        $disc.State | Should -Be 'Disconnected'
        $disc.IdleTime | Should -Be (New-TimeSpan -Days 3 -Hours 4 -Minutes 12)
    }

    It 'parses active sessions, idle formats, and the current-session marker' {
        $cur = $sessions | Where-Object UserName -EQ 'svc.monitor'
        $cur.IsCurrent | Should -BeTrue
        $cur.SessionName | Should -Be 'rdp-tcp#12'
        $cur.IdleTime | Should -Be ([timespan]::Zero)
        ($sessions | Where-Object UserName -EQ 'm.chen').IdleTime | Should -Be (New-TimeSpan -Minutes 17)
        ($sessions | Where-Object UserName -EQ 'a.okafor').IdleTime | Should -Be (New-TimeSpan -Hours 2 -Minutes 45)
    }

    It 'returns nothing when no users are logged on' {
        $none = InModuleScope InfraOps -Parameters @{ f = (Join-Path $script:fixtures 'quser-nobody.txt') } { param($f) ConvertFrom-InfraQuserOutput -Line (Get-Content $f) -ComputerName 'X' }
        $none | Should -BeNullOrEmpty
    }

    It 'Get-RemoteSessionAudit flags only disconnected sessions past the idle threshold' {
        Mock -ModuleName InfraOps Invoke-InfraQuser { Get-Content (Join-Path $script:fixtures 'quser-output.txt') }
        $r = Get-RemoteSessionAudit -ComputerName 'SRV-RDS01' -IdleThresholdHours 24
        ($r | Where-Object Flagged).UserName | Should -Be @('j.alvarez')
    }
}

Describe 'Test-DnsConsistency' {
    It 'passes when all servers agree with the expected address' {
        Mock -ModuleName InfraOps Resolve-InfraDnsName { '10.1.2.10' }
        $r = Test-DnsConsistency -Name 'app.corp.example' -Server '10.0.0.4', '10.0.0.5' -Expected @{ 'app.corp.example' = '10.1.2.10' }
        $r.Consistent | Should -BeTrue
    }

    It 'detects servers that disagree (stale record on one server)' {
        Mock -ModuleName InfraOps Resolve-InfraDnsName -ParameterFilter { $Server -eq '10.0.0.4' } { '10.1.2.10' }
        Mock -ModuleName InfraOps Resolve-InfraDnsName -ParameterFilter { $Server -eq '10.0.0.5' } { '10.1.9.99' }
        $r = Test-DnsConsistency -Name 'app.corp.example' -Server '10.0.0.4', '10.0.0.5' -WarningAction SilentlyContinue
        $r.Consistent | Should -BeFalse
        $r.Issues[0] | Should -Match 'Servers disagree'
    }

    It 'reports a server that does not answer' {
        Mock -ModuleName InfraOps Resolve-InfraDnsName -ParameterFilter { $Server -eq '10.0.0.6' } { throw 'timeout' }
        Mock -ModuleName InfraOps Resolve-InfraDnsName -ParameterFilter { $Server -ne '10.0.0.6' } { '10.1.2.10' }
        $r = Test-DnsConsistency -Name 'app.corp.example' -Server '10.0.0.4', '10.0.0.6' -WarningAction SilentlyContinue
        $r.Issues | Should -Contain 'No answer from 10.0.0.6'
    }
}

Describe 'Get-TlsCertificateExpiry' {
    It 'classifies <Expect> for a certificate expiring in <Days> days with errors "<Err>"' -ForEach @(
        @{ Days = 200; Err = 'None';                          Expect = 'OK' }
        @{ Days = 20;  Err = 'None';                          Expect = 'Warning' }
        @{ Days = 3;   Err = 'None';                          Expect = 'Critical' }
        @{ Days = -5;  Err = 'None';                          Expect = 'Critical' }
        @{ Days = 200; Err = 'RemoteCertificateNameMismatch'; Expect = 'NameMismatch' }
        @{ Days = 200; Err = 'RemoteCertificateChainErrors';  Expect = 'Untrusted' }
    ) {
        Mock -ModuleName InfraOps Get-InfraRemoteCertificate {
            [pscustomobject]@{ Subject = 'CN=portal.example.com'; Issuer = 'CN=Example CA'; NotAfter = (Get-Date).AddDays($Days).AddHours(1); Thumbprint = 'AB12'; PolicyErrors = $Err }
        }
        (Get-TlsCertificateExpiry -Endpoint 'portal.example.com').Status | Should -Be $Expect
    }

    It 'parses host:port and defaults to 443' {
        Mock -ModuleName InfraOps Get-InfraRemoteCertificate { [pscustomobject]@{ NotAfter = (Get-Date).AddDays(100); PolicyErrors = 'None'; Subject = ''; Issuer = ''; Thumbprint = '' } }
        (Get-TlsCertificateExpiry -Endpoint 'dc01.corp.example:636').Endpoint | Should -Be 'dc01.corp.example:636'
        (Get-TlsCertificateExpiry -Endpoint 'portal.example.com').Endpoint | Should -Be 'portal.example.com:443'
    }

    It 'returns Unreachable instead of throwing' {
        Mock -ModuleName InfraOps Get-InfraRemoteCertificate { throw 'TCP connect timed out' }
        (Get-TlsCertificateExpiry -Endpoint 'down.example.com' -WarningAction SilentlyContinue).Status | Should -Be 'Unreachable'
    }

    It 'rejects malformed endpoints' {
        { Get-TlsCertificateExpiry -Endpoint 'https://portal.example.com/path' } | Should -Throw
    }
}

Describe 'Get-EntraGuestAccessReport' {
    It 'classifies guests by invitation state and sign-in recency' {
        $now = (Get-Date).ToUniversalTime()
        Mock -ModuleName InfraOps Get-InfraEntraGuest {
            [pscustomobject]@{ DisplayName = 'Active Partner';  ExternalUserState = 'Accepted';          CreatedDateTime = $now.AddYears(-1);  SignInActivity = [pscustomobject]@{ LastSignInDateTime = $now.AddDays(-3);   LastNonInteractiveSignInDateTime = $null } }
            [pscustomobject]@{ DisplayName = 'Old Contractor';  ExternalUserState = 'Accepted';          CreatedDateTime = $now.AddYears(-2);  SignInActivity = [pscustomobject]@{ LastSignInDateTime = $now.AddDays(-300); LastNonInteractiveSignInDateTime = $now.AddDays(-250) } }
            [pscustomobject]@{ DisplayName = 'Never Accepted';  ExternalUserState = 'PendingAcceptance'; CreatedDateTime = $now.AddDays(-200); SignInActivity = $null }
            [pscustomobject]@{ DisplayName = 'Never Signed In'; ExternalUserState = 'Accepted';          CreatedDateTime = $now.AddDays(-150); SignInActivity = [pscustomobject]@{ LastSignInDateTime = $null; LastNonInteractiveSignInDateTime = $null } }
            [pscustomobject]@{ DisplayName = 'Just Invited';    ExternalUserState = 'PendingAcceptance'; CreatedDateTime = $now.AddDays(-2);   SignInActivity = $null }
        }
        $r = Get-EntraGuestAccessReport -StaleDays 90
        ($r | Where-Object DisplayName -EQ 'Active Partner').Classification  | Should -Be 'Active'
        ($r | Where-Object DisplayName -EQ 'Old Contractor').Classification  | Should -Be 'Stale'
        ($r | Where-Object DisplayName -EQ 'Old Contractor').DaysSinceSignIn | Should -Be 250
        ($r | Where-Object DisplayName -EQ 'Never Accepted').Classification  | Should -Be 'PendingInvitation'
        ($r | Where-Object DisplayName -EQ 'Never Signed In').Classification | Should -Be 'NeverSignedIn'
        ($r | Where-Object DisplayName -EQ 'Just Invited').Classification    | Should -Be 'Active'
    }
}

Describe 'Get-AzVmRetirementReport' {
    It 'maps <Size> to <Series>' -ForEach @(
        @{ Size = 'Standard_DS3_v2';        Series = 'Dsv2' }
        @{ Size = 'Standard_DS12_v2_Promo'; Series = 'Dsv2' }
        @{ Size = 'Standard_D2_v2';         Series = 'Dv2' }
        @{ Size = 'Standard_B2ms';          Series = 'B (v1)' }
        @{ Size = 'Standard_A4_v2';         Series = 'Av2' }
        @{ Size = 'Standard_F8s_v2';        Series = 'Fsv2' }
        @{ Size = 'Standard_GS4-8';         Series = 'Gs' }
        @{ Size = 'Standard_L8s_v2';        Series = 'Lsv2' }
        @{ Size = 'Standard_E16-4s_v3';     Series = 'Esv3' }
    ) {
        $m = InModuleScope InfraOps -Parameters @{ s = $Size } { param($s) Get-InfraVmSeriesStatus -VmSize $s }
        $m.Series | Should -Be $Series
    }

    It 'does not flag current-generation size <_>' -ForEach @('Standard_B2s_v2', 'Standard_D4s_v5', 'Standard_D4ds_v5', 'Standard_E4as_v6', 'Standard_L8s_v3') {
        InModuleScope InfraOps -Parameters @{ s = $_ } { param($s) Get-InfraVmSeriesStatus -VmSize $s } | Should -BeNullOrEmpty
    }

    It 'marks a series Retired once its date has passed' {
        $m = InModuleScope InfraOps { Get-InfraVmSeriesStatus -VmSize 'Standard_DS3_v2' -Today ([datetime]'2028-06-01') }
        $m.Status | Should -Be 'Retired'
        $m.DaysUntilRetirement | Should -BeLessThan 0
    }

    It 'excludes end-of-life series unless requested' {
        Mock -ModuleName InfraOps Get-InfraAzTenantId { '00000000-0000-0000-0000-000000000001' }
        Mock -ModuleName InfraOps Invoke-InfraResourceGraph {
            [pscustomobject]@{ subscriptionName = 'Contoso-Prod'; resourceGroup = 'rg-app'; name = 'app-01'; type = 'microsoft.compute/virtualmachines'; location = 'eastus2'; vmSize = 'Standard_D4s_v3'; powerState = 'PowerState/running' }
            [pscustomobject]@{ subscriptionName = 'Contoso-Prod'; resourceGroup = 'rg-app'; name = 'app-02'; type = 'microsoft.compute/virtualmachines'; location = 'eastus2'; vmSize = 'Standard_DS3_v2'; powerState = 'PowerState/running' }
            [pscustomobject]@{ subscriptionName = 'Contoso-Prod'; resourceGroup = 'rg-app'; name = 'app-03'; type = 'microsoft.compute/virtualmachines'; location = 'eastus2'; vmSize = 'Standard_D4s_v5'; powerState = 'PowerState/running' }
        }
        (Get-AzVmRetirementReport).Name | Should -Be @('app-02')
        (Get-AzVmRetirementReport -IncludeEndOfLife).Name | Should -Be @('app-01', 'app-02')
    }
}

Describe 'Export-InfraReport' {
    BeforeAll {
        $rows = @(
            [pscustomobject]@{ ComputerName = 'SRV-APP01'; Status = 'Healthy';  Findings = @() }
            [pscustomobject]@{ ComputerName = 'SRV-SQL01'; Status = 'Critical'; Findings = @('Disk C: 6% free', '<script>alert(1)</script>') }
        )
    }

    It 'HTML-encodes collected values so they cannot inject markup' {
        $p = Join-Path $TestDrive 'r.html'
        $rows | Export-InfraReport -Path $p
        $html = Get-Content -Raw $p
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
    }

    It 'highlights Critical rows' {
        $p = Join-Path $TestDrive 'r2.html'
        $rows | Export-InfraReport -Path $p
        (Get-Content -Raw $p) | Should -Match '<tr class="bad"><td>SRV-SQL01'
    }

    It 'flattens arrays for CSV and keeps them as arrays in JSON' {
        $csv = Join-Path $TestDrive 'r.csv'; $json = Join-Path $TestDrive 'r.json'
        $rows | Export-InfraReport -Path $csv
        $rows | Export-InfraReport -Path $json
        (Import-Csv $csv)[1].Findings | Should -Be 'Disk C: 6% free; <script>alert(1)</script>'
        (Get-Content -Raw $json | ConvertFrom-Json)[1].Findings.Count | Should -Be 2
    }

    It 'rejects unsupported formats' {
        { $rows | Export-InfraReport -Path (Join-Path $TestDrive 'r.xlsx') } | Should -Throw
    }

    It 'writes nothing with -WhatIf' {
        $p = Join-Path $TestDrive 'whatif.html'
        $rows | Export-InfraReport -Path $p -WhatIf
        Test-Path $p | Should -BeFalse
    }
}

Describe 'Logging' {
    It 'writes structured JSON lines when a log path is configured' {
        $log = Join-Path $TestDrive 'infraops.log'
        $cfg = Join-Path $TestDrive 'log.psd1'
        "@{ Logging = @{ Path = '$log' } }" | Set-Content $cfg
        Get-InfraOpsConfig -Path $cfg | Out-Null
        [pscustomobject]@{ A = 1 } | Export-InfraReport -Path (Join-Path $TestDrive 'x.csv')
        $entry = Get-Content $log | Select-Object -Last 1 | ConvertFrom-Json
        $entry.level | Should -Be 'Info'
        $entry.operation | Should -Be 'Export-InfraReport'
        $entry.message | Should -Match 'Wrote 1 row'
        { [datetime]$entry.timestamp } | Should -Not -Throw
    }

    AfterAll { InModuleScope InfraOps { $script:InfraOpsConfig = $null } }
}
