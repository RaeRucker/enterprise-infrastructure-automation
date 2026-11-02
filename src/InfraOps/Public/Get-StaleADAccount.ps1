function Get-StaleADAccount {
    <#
    .SYNOPSIS
        Reports enabled Active Directory users or computers with no logon in N days. Read-only.
    .DESCRIPTION
        Uses lastLogonTimestamp, which replicates to every domain controller but is only
        updated when the previous value is older than about 14 days
        (ms-DS-Logon-Time-Sync-Interval). An account reported here has been inactive for
        at least InactiveDays minus roughly 14 days; treat it as a candidate for review,
        not proof of abandonment.

        Accounts created within the inactivity window are excluded (new accounts that
        haven't been used yet are not stale).
    .PARAMETER Type
        User or Computer.
    .PARAMETER InactiveDays
        Defaults to Thresholds.StaleAccountDays in the configuration (90).
    .PARAMETER SearchBase
        Limit to an OU, for example 'OU=Workstations,DC=corp,DC=example'.
    .EXAMPLE
        Get-StaleADAccount -Type Computer -InactiveDays 120 | Export-InfraReport -Path ./output/stale-computers.csv
    .EXAMPLE
        # Review, then disable with confirmation
        Get-StaleADAccount -Type User | Out-GridView -PassThru | Disable-StaleADAccount -WhatIf
    .OUTPUTS
        InfraOps.StaleAccount
    .NOTES
        Requires: ActiveDirectory module; read access to the domain (any authenticated user by default).
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.StaleAccount')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('User', 'Computer')]
        [string] $Type,

        [ValidateRange(14, 3650)]
        [int] $InactiveDays = (Get-InfraOpsConfig).Thresholds.StaleAccountDays,

        [string] $SearchBase,

        [string] $Server
    )

    $now = (Get-Date).ToUniversalTime()
    $cutoff = $now.AddDays(-$InactiveDays)
    $accounts = @(Get-InfraADAccount -Type $Type -SearchBase $SearchBase -Server $Server)

    $stale = foreach ($a in $accounts) {
        if (-not $a.Enabled) { continue }
        if ($a.whenCreated -and ([datetime]$a.whenCreated).ToUniversalTime() -gt $cutoff) { continue }

        $lastLogon = ConvertFrom-InfraFileTime $a.lastLogonTimestamp
        if ($lastLogon -and $lastLogon -gt $cutoff) { continue }

        $daysInactive = if ($lastLogon) { [int]($now - $lastLogon).TotalDays } else { $null }
        [pscustomobject]@{
            PSTypeName           = 'InfraOps.StaleAccount'
            Type                 = $Type
            Name                 = $a.Name
            SamAccountName       = $a.SamAccountName
            LastLogon            = $lastLogon
            DaysInactive         = $daysInactive
            NeverLoggedOn        = -not $lastLogon
            PasswordNeverExpires = [bool]$a.PasswordNeverExpires
            WhenCreated          = $a.whenCreated
            DistinguishedName    = $a.DistinguishedName
            Recommendation       = if ($a.PasswordNeverExpires) { 'Review owner first: non-expiring password suggests a service account' } else { 'Disable, then delete after the retention period' }
        }
    }

    Write-InfraLog -Level Info -Message "$(@($stale).Count) stale $Type account(s) of $($accounts.Count) (>$InactiveDays days)" -Data @{ type = $Type; inactiveDays = $InactiveDays }
    $stale | Sort-Object @{ e = { if ($_.NeverLoggedOn) { [int]::MaxValue } else { $_.DaysInactive } }; Descending = $true }
}
