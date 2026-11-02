function Test-DnsConsistency {
    <#
    .SYNOPSIS
        Resolves names against several DNS servers and reports disagreement or unexpected answers.
    .DESCRIPTION
        Catches the DNS faults that cause "works for some users" incidents:
          - Servers return different answers (replication lag, a stale record on one DC,
            or split-brain zones)
          - The answer differs from the expected address (record changed during a
            migration, or never updated)
          - One server fails to answer at all

        Each name/server pair is queried directly (no cache, recursion as the server
        performs it).
    .PARAMETER Name
        Names to resolve (FQDN recommended).
    .PARAMETER Server
        DNS servers to query, for example each domain controller.
    .PARAMETER Expected
        Optional hashtable of name -> expected address(es).
    .PARAMETER Type
        Record type. Defaults to A.
    .EXAMPLE
        Test-DnsConsistency -Name app.corp.example -Server 10.0.0.4, 10.0.0.5 -Expected @{ 'app.corp.example' = '10.1.2.10' }
    .OUTPUTS
        InfraOps.DnsCheck
    .NOTES
        Requires: Resolve-DnsName (DnsClient module, Windows) and UDP/TCP 53 to each server.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.DnsCheck')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name,

        [Parameter(Mandatory)]
        [ValidateCount(1, 20)]
        [string[]] $Server,

        [hashtable] $Expected = @{},

        [ValidateSet('A', 'AAAA', 'CNAME')]
        [string] $Type = 'A'
    )

    foreach ($n in $Name) {
        $answers = [ordered]@{}
        foreach ($s in $Server) {
            try {
                $records = Resolve-InfraDnsName -Name $n -Server $s -Type $Type
                $answers[$s] = @($records | Sort-Object -Unique)
            }
            catch {
                $answers[$s] = $null
            }
        }

        $issues = [System.Collections.Generic.List[string]]::new()
        $failed = @($answers.Keys | Where-Object { $null -eq $answers[$_] })
        foreach ($f in $failed) { $issues.Add("No answer from $f") }

        $distinct = @($answers.Values | Where-Object { $null -ne $_ } | ForEach-Object { ($_ -join ',') } | Sort-Object -Unique)
        if ($distinct.Count -gt 1) { $issues.Add("Servers disagree: $(($answers.Keys | Where-Object { $null -ne $answers[$_] } | ForEach-Object { "$_=$($answers[$_] -join ',')" }) -join '; ')") }

        if ($Expected.ContainsKey($n)) {
            $want = (@($Expected[$n]) | Sort-Object -Unique) -join ','
            foreach ($s in $answers.Keys | Where-Object { $null -ne $answers[$_] }) {
                $got = $answers[$s] -join ','
                if ($got -ne $want) { $issues.Add("$s returned $got, expected $want") }
            }
        }

        [pscustomobject]@{
            PSTypeName = 'InfraOps.DnsCheck'
            Name       = $n
            Type       = $Type
            Consistent = $issues.Count -eq 0
            Answers    = [pscustomobject]$answers
            Issues     = $issues.ToArray()
        }
        if ($issues.Count) { Write-InfraLog -Level Warning -Message "$n inconsistent: $($issues -join ' | ')" }
    }
}

function Resolve-InfraDnsName {
    <# Wrapper so tests can mock DNS answers on any platform. Returns address/target strings. #>
    [CmdletBinding()]
    param([string] $Name, [string] $Server, [string] $Type)
    $r = Resolve-DnsName -Name $Name -Server $Server -Type $Type -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
    switch ($Type) {
        'CNAME' { $r | Where-Object Type -EQ 'CNAME' | ForEach-Object NameHost }
        default { $r | Where-Object Type -EQ $Type | ForEach-Object IPAddress }
    }
}
