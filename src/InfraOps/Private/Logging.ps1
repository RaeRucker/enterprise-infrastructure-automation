function Write-InfraLog {
    <#
    .SYNOPSIS
        Writes a structured (JSON Lines) log entry and mirrors it to the matching PowerShell stream.
    .DESCRIPTION
        Every public function logs through this helper so that scheduled runs leave an
        audit trail that can be ingested by Log Analytics or any SIEM. When no log path
        is configured, entries go only to the Verbose/Warning/Error streams.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string] $Level,

        [Parameter(Mandatory)]
        [string] $Message,

        [string] $Operation,

        [hashtable] $Data = @{}
    )

    if (-not $Operation) {
        # First caller that isn't this helper or an anonymous script block; strip the
        # <Begin>/<Process>/<End> suffix PowerShell adds for advanced function blocks.
        $frame = Get-PSCallStack | Select-Object -Skip 1 |
            Where-Object { $_.FunctionName -notmatch '^(Write-InfraLog|<ScriptBlock>)' } | Select-Object -First 1
        $Operation = if ($frame) { $frame.FunctionName -replace '<\w+>$', '' } else { 'InfraOps' }
    }

    $entry = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        level     = $Level
        operation = $Operation
        message   = $Message
        host      = [System.Environment]::MachineName
        user      = [System.Environment]::UserName
    }
    if ($Data.Count) { $entry.data = $Data }

    $config = Get-InfraOpsConfig
    if ($config.Logging.Path) {
        $dir = Split-Path -Parent $config.Logging.Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ($entry | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path $config.Logging.Path -Encoding utf8
    }

    switch ($Level) {
        'Info'    { Write-Verbose "[$Operation] $Message" }
        'Warning' { Write-Warning "[$Operation] $Message" }
        'Error'   { Write-Error "[$Operation] $Message" -ErrorAction Continue }
    }
}
