function Get-AzVmRetirementReport {
    <#
    .SYNOPSIS
        Finds Azure VMs and scale sets on retiring or end-of-life VM series across subscriptions and tenants. Read-only.
    .DESCRIPTION
        Queries Azure Resource Graph once per tenant and matches each VM size against
        Data/vm-retirement-map.json (series pattern, retirement date, suggested
        replacement). Retirement dates change: the map records when it was last
        reviewed against Microsoft's retired sizes list.
    .PARAMETER TenantId
        Tenants to query (for MSP / B2B access). You must already be signed in to each
        (Connect-AzAccount -Tenant <id>). Defaults to the current context's tenant.
    .PARAMETER IncludeEndOfLife
        Include series with no retirement date that can no longer be bought on reserved instances.
    .EXAMPLE
        Get-AzVmRetirementReport | Export-InfraReport -Path ./output/vm-retirements.html -Title 'VM retirement audit'
    .OUTPUTS
        InfraOps.VmRetirement
    .NOTES
        Requires: Az.Accounts, Az.ResourceGraph (0.13+), and Reader on the subscriptions.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.VmRetirement')]
    param(
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string[]] $TenantId,

        [switch] $IncludeEndOfLife
    )

    $query = @'
resources
| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.compute/virtualmachinescalesets')
| extend vmSize = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.hardwareProfile.vmSize), tostring(sku.name))
| extend powerState = tostring(properties.extended.instanceView.powerState.code)
| join kind=leftouter (resourcecontainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId, subscriptionName = name) on subscriptionId
| project tenantId, subscriptionName, subscriptionId, resourceGroup, name, type, location, vmSize, powerState
'@

    $tenants = @(if ($TenantId) { $TenantId } else { Get-InfraAzTenantId })
    $inventory = foreach ($t in $tenants) {
        try { Invoke-InfraResourceGraph -Query $query -TenantId $t }
        catch { Write-InfraLog -Level Warning -Message "Tenant ${t}: $($_.Exception.Message)" }
    }

    foreach ($vm in $inventory) {
        $match = Get-InfraVmSeriesStatus -VmSize $vm.vmSize
        if (-not $match) { continue }
        if ($match.Status -eq 'EndOfLife' -and -not $IncludeEndOfLife) { continue }

        [pscustomobject]@{
            PSTypeName           = 'InfraOps.VmRetirement'
            Subscription         = $vm.subscriptionName
            ResourceGroup        = $vm.resourceGroup
            Name                 = $vm.name
            ResourceType         = if ($vm.type -match 'scalesets') { 'VM Scale Set' } else { 'VM' }
            Location             = $vm.location
            PowerState           = ($vm.powerState -replace '^PowerState/', '')
            VmSize               = $vm.vmSize
            Series               = $match.Series
            Status               = $match.Status
            RetirementDate       = $match.RetirementDate
            DaysUntilRetirement  = $match.DaysUntilRetirement
            SuggestedReplacement = $match.SuggestedReplacement
        }
    }
}

function Get-InfraVmSeriesStatus {
    <# Matches a VM size to the retirement map. Returns $null for current-generation sizes. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $VmSize, [datetime] $Today = (Get-Date).Date)

    if (-not $script:VmRetirementMap) {
        $script:VmRetirementMap = Get-Content -Raw -Path (Join-Path $script:ModuleRoot 'Data/vm-retirement-map.json') | ConvertFrom-Json
    }
    foreach ($s in $script:VmRetirementMap.series) {
        if ($VmSize -match "(?i)$($s.pattern)") {
            $date = if ($s.retirementDate) { [datetime]$s.retirementDate } else { $null }
            return [pscustomobject]@{
                Series               = $s.series
                Status               = if ($date -and $date -le $Today) { 'Retired' } else { $s.status }
                RetirementDate       = $date
                DaysUntilRetirement  = if ($date) { ($date - $Today).Days } else { $null }
                SuggestedReplacement = $s.suggestedReplacement
            }
        }
    }
    return $null
}

function Get-InfraAzTenantId {
    <# Tenant of the current Az context. Wrapped so tests don't need Az.Accounts. #>
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Azure context. Run Connect-AzAccount first.' }
    $ctx.Tenant.Id
}

function Invoke-InfraResourceGraph {
    <# Paged Resource Graph query for one tenant. Mocked in unit tests. #>
    [CmdletBinding()]
    param([string] $Query, [string] $TenantId)
    $null = Set-AzContext -Tenant $TenantId -WarningAction SilentlyContinue -ErrorAction Stop
    $skip = $null
    do {
        $p = @{ Query = $Query; First = 1000; UseTenantScope = $true }
        if ($skip) { $p.SkipToken = $skip }
        $page = Search-AzGraph @p
        $page.Data
        $skip = $page.SkipToken
    } while ($skip)
}
