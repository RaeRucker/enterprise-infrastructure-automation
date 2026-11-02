function Get-RemoteSessionAudit {
    <#
    .SYNOPSIS
        Lists interactive and RDP sessions on servers and flags long-idle disconnected sessions. Read-only.
    .DESCRIPTION
        Disconnected sessions keep the user's processes, open files, and cached
        credentials on the server. They also consume RDS session slots and commonly
        hold locks that block patching. This function reports every session, and marks
        one as Flagged when it is disconnected and idle longer than IdleThresholdHours.

        It does not log anyone off. To remove a session after review:
        logoff <Id> /server:<ComputerName>
    .EXAMPLE
        Get-RemoteSessionAudit -ComputerName SRV-APP01, SRV-APP02 | Where-Object Flagged
    .OUTPUTS
        InfraOps.RemoteSession
    .NOTES
        Requires: quser.exe (Windows) and permission to query sessions on the target
        (local Administrators or Remote Desktop Users with query rights). Uses RPC/SMB,
        not WinRM.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.RemoteSession')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name', 'DNSHostName')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$')]
        [string[]] $ComputerName,

        [ValidateRange(1, 720)]
        [int] $IdleThresholdHours = 24
    )

    process {
        foreach ($computer in $ComputerName) {
            $lines = @(Invoke-InfraQuser -ComputerName $computer)
            if ($lines -match 'Error \d+|RPC server is unavailable|Access is denied') {
                Write-InfraLog -Level Warning -Message "quser failed on ${computer}: $($lines -join ' ')"
                continue
            }

            $sessions = @(ConvertFrom-InfraQuserOutput -Line $lines -ComputerName $computer)
            foreach ($s in $sessions) {
                $flagged = $s.State -eq 'Disconnected' -and $s.IdleTime.TotalHours -ge $IdleThresholdHours
                $s | Add-Member -NotePropertyName Flagged -NotePropertyValue $flagged -PassThru |
                    Add-Member -NotePropertyName IdleHours -NotePropertyValue ([math]::Round($s.IdleTime.TotalHours, 1)) -PassThru |
                    ForEach-Object { $_.PSObject.TypeNames.Insert(0, 'InfraOps.RemoteSession'); $_ }
            }
            Write-InfraLog -Level Info -Message "$computer has $($sessions.Count) session(s), $(@($sessions | Where-Object { $_.State -eq 'Disconnected' -and $_.IdleTime.TotalHours -ge $IdleThresholdHours }).Count) flagged"
        }
    }
}
