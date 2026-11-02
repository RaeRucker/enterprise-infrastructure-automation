function Disable-StaleADAccount {
    <#
    .SYNOPSIS
        Disables accounts reported by Get-StaleADAccount. Supports -WhatIf and -Confirm.
    .DESCRIPTION
        Destructive (but reversible) operation. For each account it:
          1. Disables the account
          2. Writes a description recording when, by whom, and why
          3. Optionally moves it to a quarantine OU

        Safeguards:
          - ConfirmImpact is High, so PowerShell prompts for every account unless -Confirm:$false
          - Accepts only InfraOps.StaleAccount objects (from Get-StaleADAccount), not raw names
          - Refuses accounts with a non-expiring password unless -IncludeNonExpiringPasswords,
            because those are usually service accounts whose owners must be consulted
          - -MaxCount stops a bulk run from disabling more than expected
          - Every action (and every skip) is logged
    .EXAMPLE
        Get-StaleADAccount -Type Computer | Disable-StaleADAccount -QuarantineOU 'OU=Disabled,DC=corp,DC=example' -WhatIf
    .EXAMPLE
        $review = Get-StaleADAccount -Type User | Where-Object DaysInactive -gt 180
        $review | Disable-StaleADAccount -MaxCount 25
    .NOTES
        Requires: delegated rights to disable accounts and write the description attribute
        in the target OUs (avoid using Domain Admins for this).
        Reverse with: Enable-ADAccount -Identity <dn>; move it back with Move-ADObject.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [PSTypeName('InfraOps.StaleAccount')]
        [psobject] $InputObject,

        [ValidatePattern('^OU=.+,DC=.+')]
        [string] $QuarantineOU,

        [switch] $IncludeNonExpiringPasswords,

        [ValidateRange(1, 1000)]
        [int] $MaxCount = 50,

        [string] $Server
    )

    begin {
        $processed = 0
        $operator = [System.Environment]::UserName
    }

    process {
        foreach ($account in $InputObject) {
            if ($processed -ge $MaxCount) {
                Write-InfraLog -Level Warning -Message "MaxCount ($MaxCount) reached; skipping $($account.SamAccountName) and any remaining accounts"
                return
            }
            if ($account.PasswordNeverExpires -and -not $IncludeNonExpiringPasswords) {
                Write-InfraLog -Level Warning -Message "Skipped $($account.SamAccountName): password never expires (likely a service account). Use -IncludeNonExpiringPasswords after confirming with the owner."
                continue
            }

            $inactive = if ($account.NeverLoggedOn) { 'never logged on' } else { "inactive $($account.DaysInactive) days" }
            $description = "Disabled by InfraOps $(Get-Date -Format 'yyyy-MM-dd') ($operator): $inactive"
            $target = "$($account.SamAccountName) ($($account.DistinguishedName))"

            if ($PSCmdlet.ShouldProcess($target, "Disable account$(if ($QuarantineOU) { " and move to $QuarantineOU" })")) {
                try {
                    Disable-InfraADAccount -DistinguishedName $account.DistinguishedName -Description $description -TargetPath $QuarantineOU -Server $Server
                    $processed++
                    Write-InfraLog -Level Info -Message "Disabled $($account.SamAccountName)" -Data @{ dn = $account.DistinguishedName; quarantine = $QuarantineOU }
                    [pscustomobject]@{ SamAccountName = $account.SamAccountName; Action = 'Disabled'; Detail = $description }
                }
                catch {
                    Write-InfraLog -Level Error -Message "Failed to disable $($account.SamAccountName): $($_.Exception.Message)"
                    [pscustomobject]@{ SamAccountName = $account.SamAccountName; Action = 'Failed'; Detail = $_.Exception.Message }
                }
            }
        }
    }
}
