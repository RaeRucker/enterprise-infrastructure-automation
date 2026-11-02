function Get-InfraOptionalProperty {
    <# Returns a property value, or $null when the object or property is absent (safe under Set-StrictMode). #>
    param($InputObject, [Parameter(Mandatory)] [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}
