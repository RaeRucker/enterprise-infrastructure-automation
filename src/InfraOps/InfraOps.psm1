#Requires -Version 7.2
Set-StrictMode -Version Latest

# Dot-source private helpers first, then public functions.
foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        . $file.FullName
    }
}

# Module-wide state: the active configuration and log file.
$script:InfraOpsConfig = $null
$script:VmRetirementMap = $null
$script:ModuleRoot = $PSScriptRoot
