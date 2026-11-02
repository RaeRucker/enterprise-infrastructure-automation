# Thin wrappers around CIM so public functions can be unit tested with Pester mocks
# and so connection handling (sessions, credentials, cleanup) lives in one place.

function Open-InfraCimSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [pscredential] $Credential
    )
    $params = @{ ComputerName = $ComputerName; ErrorAction = 'Stop'; OperationTimeoutSec = 30 }
    if ($Credential) { $params.Credential = $Credential }
    New-CimSession @params
}

function Invoke-InfraCimQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $CimSession,
        [Parameter(Mandatory)] [string] $ClassName,
        [string] $Filter
    )
    $params = @{ CimSession = $CimSession; ClassName = $ClassName; ErrorAction = 'Stop' }
    if ($Filter) { $params.Filter = $Filter }
    Get-CimInstance @params
}

function Test-InfraPendingReboot {
    <# Returns the list of reasons a reboot is pending (empty when none). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)] $CimSession)

    $HKLM = [uint32]2147483650
    $checks = @(
        @{ Reason = 'Component Based Servicing'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'; SubKey = 'RebootPending' }
        @{ Reason = 'Windows Update';            Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update'; SubKey = 'RebootRequired' }
    )
    $reasons = foreach ($c in $checks) {
        $r = Invoke-CimMethod -CimSession $CimSession -Namespace root/default -ClassName StdRegProv -MethodName EnumKey `
            -Arguments @{ hDefKey = $HKLM; sSubKeyName = $c.Key } -ErrorAction SilentlyContinue
        if ($r -and $r.sNames -contains $c.SubKey) { $c.Reason }
    }

    $pfro = Invoke-CimMethod -CimSession $CimSession -Namespace root/default -ClassName StdRegProv -MethodName GetMultiStringValue `
        -Arguments @{ hDefKey = $HKLM; sSubKeyName = 'SYSTEM\CurrentControlSet\Control\Session Manager'; sValueName = 'PendingFileRenameOperations' } `
        -ErrorAction SilentlyContinue
    if ($pfro -and $pfro.sValue) { $reasons = @($reasons) + 'Pending file rename operations' }

    return @($reasons)
}

function Close-InfraCimSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $CimSession)
    Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
}
