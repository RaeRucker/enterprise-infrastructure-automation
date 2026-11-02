# Wrappers around the ActiveDirectory module. They keep the public functions
# testable on machines without RSAT (Pester mocks these) and centralize the
# property lists each query needs.

function Assert-InfraADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'The ActiveDirectory module (RSAT) is required. Install: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    }
}

function Get-InfraADAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('User', 'Computer')] [string] $Type,
        [string] $SearchBase,
        [string] $Server
    )
    Assert-InfraADModule
    $params = @{
        Filter     = '*'
        Properties = 'lastLogonTimestamp', 'whenCreated', 'PasswordLastSet', 'PasswordNeverExpires', 'Description', 'DistinguishedName', 'Enabled'
    }
    if ($SearchBase) { $params.SearchBase = $SearchBase }
    if ($Server) { $params.Server = $Server }
    if ($Type -eq 'User') { ActiveDirectory\Get-ADUser @params } else { ActiveDirectory\Get-ADComputer @params }
}

function Get-InfraADGroupMember {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Identity,
        [string] $Server
    )
    Assert-InfraADModule
    $params = @{ Identity = $Identity; Recursive = $true }
    if ($Server) { $params.Server = $Server }
    ActiveDirectory\Get-ADGroupMember @params |
        Where-Object objectClass -EQ 'user' |
        ForEach-Object {
            $u = @{ Identity = $_.DistinguishedName; Properties = 'lastLogonTimestamp', 'PasswordNeverExpires', 'PasswordLastSet', 'Enabled' }
            if ($Server) { $u.Server = $Server }
            ActiveDirectory\Get-ADUser @u
        }
}

function Disable-InfraADAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DistinguishedName,
        [Parameter(Mandatory)] [string] $Description,
        [string] $TargetPath,
        [string] $Server
    )
    Assert-InfraADModule
    $common = @{ Identity = $DistinguishedName; ErrorAction = 'Stop' }
    if ($Server) { $common.Server = $Server }
    ActiveDirectory\Disable-ADAccount @common
    ActiveDirectory\Set-ADObject @common -Replace @{ description = $Description }
    if ($TargetPath) { ActiveDirectory\Move-ADObject @common -TargetPath $TargetPath }
}

function ConvertFrom-InfraFileTime {
    <# lastLogonTimestamp is a Windows FILETIME (Int64). 0 or null means never. #>
    param($FileTime)
    if (-not $FileTime -or [int64]$FileTime -le 0) { return $null }
    [datetime]::FromFileTimeUtc([int64]$FileTime)
}
