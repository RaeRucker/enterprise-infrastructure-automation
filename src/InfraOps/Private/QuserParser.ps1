function Invoke-InfraQuser {
    <# Runs quser.exe against a server. Wrapped so tests can supply synthetic output. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] [string] $ComputerName)
    $output = & quser.exe "/server:$ComputerName" 2>&1
    # quser exits 1 with "No User exists for *" when nobody is logged on.
    return @($output | ForEach-Object { "$_" })
}

function ConvertTo-InfraIdleTime {
    <#
        Converts quser idle values to a TimeSpan.
        Formats: '.', 'none' (not idle), 'M' (minutes), 'H:MM', 'D+HH:MM'.
    #>
    [OutputType([timespan])]
    param([string] $Value)
    $v = $Value.Trim()
    if ($v -in '', '.', 'none') { return [timespan]::Zero }
    if ($v -match '^(\d+)\+(\d+):(\d+)$') { return New-TimeSpan -Days $Matches[1] -Hours $Matches[2] -Minutes $Matches[3] }
    if ($v -match '^(\d+):(\d+)$')        { return New-TimeSpan -Hours $Matches[1] -Minutes $Matches[2] }
    if ($v -match '^\d+$')                { return New-TimeSpan -Minutes $v }
    throw "Unrecognized idle time '$Value'"
}

function ConvertFrom-InfraQuserOutput {
    <#
        Parses quser's fixed-width table. Column positions come from the header line,
        because SESSIONNAME is blank for disconnected sessions and splitting on
        whitespace would shift every following column.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Line,
        [Parameter(Mandatory)] [string] $ComputerName
    )

    $header = $Line | Where-Object { $_ -match 'USERNAME\s+SESSIONNAME' } | Select-Object -First 1
    if (-not $header) { return }   # "No User exists for *" or an error message

    $sessionCol = $header.IndexOf('SESSIONNAME')
    $stateCol   = $header.IndexOf('STATE')
    $logonCol   = $header.IndexOf('LOGON TIME')

    foreach ($row in $Line | Where-Object { $_ -ne $header -and $_.Trim() }) {
        if ($row.Length -lt $logonCol) { continue }

        $username = $row.Substring(1, $sessionCol - 1).Trim()

        # "rdp-tcp#5   2" for active sessions, "   3" for disconnected ones:
        # the last token is the ID, anything before it is the session name.
        $sessionAndId = $row.Substring($sessionCol, $stateCol - $sessionCol).Trim() -split '\s+'
        $id = [int]$sessionAndId[-1]
        $session = ($sessionAndId | Select-Object -SkipLast 1) -join ' '

        # "Active          ." : state is left-aligned, idle time is right-aligned.
        $stateAndIdle = $row.Substring($stateCol, $logonCol - $stateCol).Trim() -split '\s+'
        $state = $stateAndIdle[0]
        $idle = if ($stateAndIdle.Count -gt 1) { $stateAndIdle[-1] } else { '.' }

        $logon = $null
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($row.Substring($logonCol).Trim(), [cultureinfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $logon = $parsed
        }

        [pscustomobject]@{
            ComputerName = $ComputerName
            UserName     = $username
            SessionName  = $session
            Id           = $id
            State        = if ($state -eq 'Disc') { 'Disconnected' } else { $state }
            IdleTime     = ConvertTo-InfraIdleTime $idle
            LogonTime    = $logon
            IsCurrent    = $row.StartsWith('>')
        }
    }
}
