function Get-EntraGuestAccessReport {
    <#
    .SYNOPSIS
        Reports Microsoft Entra ID guest accounts with their last sign-in and invitation state. Read-only.
    .DESCRIPTION
        Guest accounts accumulate after projects end and are a common external-access
        risk. Each guest is classified:
          - PendingInvitation: invited, never redeemed, older than the stale threshold
          - NeverSignedIn:     redeemed but no recorded sign-in
          - Stale:             last sign-in older than StaleAccountDays
          - Active

        Uses the signInActivity property, which records interactive and
        non-interactive sign-ins.
    .EXAMPLE
        Connect-MgGraph -Scopes 'User.Read.All','AuditLog.Read.All'
        Get-EntraGuestAccessReport | Where-Object Classification -ne 'Active' | Export-InfraReport -Path ./output/guests.csv
    .OUTPUTS
        InfraOps.GuestAccount
    .NOTES
        Requires: Microsoft.Graph.Users module, delegated or application permissions
        User.Read.All and AuditLog.Read.All, and Microsoft Entra ID P1 or P2
        (signInActivity is unavailable on free tenants). Read-only: no consent for write
        scopes is needed.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.GuestAccount')]
    param(
        [ValidateRange(14, 3650)]
        [int] $StaleDays = (Get-InfraOpsConfig).Thresholds.StaleAccountDays
    )

    $now = (Get-Date).ToUniversalTime()
    $cutoff = $now.AddDays(-$StaleDays)
    $guests = @(Get-InfraEntraGuest)

    foreach ($g in $guests) {
        # Graph objects omit properties that weren't selected or have no value; read defensively.
        $activity = Get-InfraOptionalProperty $g 'SignInActivity'
        $lastSignIn = Get-InfraOptionalProperty $activity 'LastSignInDateTime'
        $nonInteractive = Get-InfraOptionalProperty $activity 'LastNonInteractiveSignInDateTime'
        $latest = @($lastSignIn, $nonInteractive) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        $created = [datetime]$g.CreatedDateTime

        $classification = if ($g.ExternalUserState -eq 'PendingAcceptance') {
            if ($created -lt $cutoff) { 'PendingInvitation' } else { 'Active' }
        } elseif (-not $latest) {
            if ($created -lt $cutoff) { 'NeverSignedIn' } else { 'Active' }
        } elseif ([datetime]$latest -lt $cutoff) {
            'Stale'
        } else { 'Active' }

        [pscustomobject]@{
            PSTypeName        = 'InfraOps.GuestAccount'
            DisplayName       = $g.DisplayName
            Mail              = Get-InfraOptionalProperty $g 'Mail'
            UserPrincipalName = Get-InfraOptionalProperty $g 'UserPrincipalName'
            InvitationState   = $g.ExternalUserState
            Created           = $created
            LastSignIn        = $latest
            DaysSinceSignIn   = if ($latest) { [int]($now - [datetime]$latest).TotalDays } else { $null }
            AccountEnabled    = Get-InfraOptionalProperty $g 'AccountEnabled'
            Classification    = $classification
        }
    }
    Write-InfraLog -Level Info -Message "$($guests.Count) guest account(s) evaluated (stale threshold $StaleDays days)"
}

function Get-InfraEntraGuest {
    <# Wrapper around Microsoft Graph so tests can supply synthetic guests. #>
    [CmdletBinding()]
    param()
    if (-not (Get-Command Get-MgUser -ErrorAction SilentlyContinue)) {
        throw 'Microsoft.Graph.Users is required: Install-Module Microsoft.Graph.Users; Connect-MgGraph -Scopes User.Read.All,AuditLog.Read.All'
    }
    Get-MgUser -All -Filter "userType eq 'Guest'" -ConsistencyLevel eventual `
        -Property 'displayName,mail,userPrincipalName,externalUserState,createdDateTime,accountEnabled,signInActivity'
}
