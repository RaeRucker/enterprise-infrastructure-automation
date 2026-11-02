function Get-PrivilegedGroupMembership {
    <#
    .SYNOPSIS
        Lists effective (nested) members of privileged AD groups and flags risky ones. Read-only.
    .DESCRIPTION
        Expands nested groups so that indirect membership (a user in a group that is in
        Domain Admins) is visible. Each member is flagged when:
          - the password never expires
          - the password is older than one year
          - the account is enabled but has not logged on in StaleAccountDays
          - the account is disabled but still a member
    .PARAMETER Group
        Groups to audit. Defaults to PrivilegedGroups in the configuration.
    .EXAMPLE
        Get-PrivilegedGroupMembership | Where-Object Flags | Format-Table Group, SamAccountName, Flags
    .OUTPUTS
        InfraOps.PrivilegedMember
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.PrivilegedMember')]
    param(
        [string[]] $Group = (Get-InfraOpsConfig).PrivilegedGroups,
        [string] $Server
    )

    $config = Get-InfraOpsConfig
    $now = (Get-Date).ToUniversalTime()
    $staleCutoff = $now.AddDays(-$config.Thresholds.StaleAccountDays)

    foreach ($g in $Group) {
        try {
            $members = @(Get-InfraADGroupMember -Identity $g -Server $Server)
        }
        catch {
            Write-InfraLog -Level Warning -Message "Cannot read group '$g': $($_.Exception.Message)"
            continue
        }

        foreach ($m in $members) {
            $lastLogon = ConvertFrom-InfraFileTime $m.lastLogonTimestamp
            $flags = [System.Collections.Generic.List[string]]::new()
            if ($m.PasswordNeverExpires) { $flags.Add('PasswordNeverExpires') }
            if ($m.PasswordLastSet -and ([datetime]$m.PasswordLastSet).ToUniversalTime() -lt $now.AddDays(-365)) { $flags.Add('PasswordOlderThan1Year') }
            if ($m.Enabled -and (-not $lastLogon -or $lastLogon -lt $staleCutoff)) { $flags.Add('Stale') }
            if (-not $m.Enabled) { $flags.Add('DisabledButMember') }

            [pscustomobject]@{
                PSTypeName       = 'InfraOps.PrivilegedMember'
                Group            = $g
                SamAccountName   = $m.SamAccountName
                Name             = $m.Name
                Enabled          = [bool]$m.Enabled
                LastLogon        = $lastLogon
                PasswordLastSet  = $m.PasswordLastSet
                Flags            = $flags.ToArray()
            }
        }
        Write-InfraLog -Level Info -Message "$g has $($members.Count) effective user member(s)"
    }
}
