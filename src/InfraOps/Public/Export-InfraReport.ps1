function Export-InfraReport {
    <#
    .SYNOPSIS
        Writes any InfraOps output (or other objects) to HTML, CSV, or JSON.
    .DESCRIPTION
        The format comes from the file extension. HTML output is a single self-contained
        file with every value HTML-encoded, so data collected from systems (service names,
        descriptions, certificate subjects) can't inject markup or script into the report.
        Array properties are joined with '; ' for HTML and CSV, and kept as arrays in JSON.

        Rows whose Status or Classification is Critical, Unreachable, Failed, or Stale are
        highlighted in HTML.
    .EXAMPLE
        Get-ServerHealth -ComputerName (Get-Content ./config/servers.txt) | Export-InfraReport -Path ./output/health.html -Title 'Daily server health'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]] $InputObject,

        [Parameter(Mandatory)]
        [ValidatePattern('\.(html|csv|json)$')]
        [string] $Path,

        [string] $Title = 'Infrastructure report',

        [switch] $PassThru
    )

    begin { $rows = [System.Collections.Generic.List[psobject]]::new() }
    process { foreach ($o in $InputObject) { $rows.Add($o) } }

    end {
        $format = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLower()
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        $flatten = {
            param($obj)
            $h = [ordered]@{}
            foreach ($p in $obj.PSObject.Properties) {
                $v = $p.Value
                $h[$p.Name] = if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
                    (@($v) | ForEach-Object { if ($_ -is [psobject] -and @($_.PSObject.Properties).Count -gt 1 -and $_ -isnot [string]) { ($_.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ' } else { "$_" } }) -join '; '
                } elseif ($v -is [datetime]) { $v.ToString('yyyy-MM-dd HH:mm') } else { $v }
            }
            [pscustomobject]$h
        }

        if (-not $PSCmdlet.ShouldProcess($Path, "Write $($rows.Count) row(s) as $format")) { return }

        switch ($format) {
            'json' { $rows | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding utf8 }
            'csv'  { $rows | ForEach-Object { & $flatten $_ } | Export-Csv -Path $Path -NoTypeInformation -Encoding utf8 }
            'html' {
                $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
                $flat = @($rows | ForEach-Object { & $flatten $_ })
                $columns = if ($flat.Count) { $flat[0].PSObject.Properties.Name } else { @() }
                $bad = 'Critical', 'Unreachable', 'Failed', 'Stale', 'Retired', 'NameMismatch', 'Untrusted'
                $warn = 'Warning', 'Urgent', 'NeverSignedIn', 'PendingInvitation'

                $body = foreach ($r in $flat) {
                    $state = "$($r.PSObject.Properties['Status']?.Value)$($r.PSObject.Properties['Classification']?.Value)"
                    $class = if ($state -in $bad) { ' class="bad"' } elseif ($state -in $warn) { ' class="warn"' } else { '' }
                    "<tr$class>" + (($columns | ForEach-Object { "<td>$(& $enc $r.$_)</td>" }) -join '') + '</tr>'
                }
                $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>$(& $enc $Title)</title>
<style>
body{font-family:Segoe UI,system-ui,sans-serif;margin:24px;color:#1f2937}
h1{font-size:20px;margin:0 0 4px} p{color:#6b7280;margin:0 0 16px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border-bottom:1px solid #e5e7eb;padding:6px 8px;text-align:left;vertical-align:top}
th{background:#f3f4f6} td{min-width:70px} td:nth-child(3){min-width:260px}
tr.bad td{background:#fef2f2} tr.warn td{background:#fffbeb}
</style></head><body>
<h1>$(& $enc $Title)</h1>
<p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $(& $enc ([System.Environment]::MachineName)) &middot; $($rows.Count) row(s)</p>
<table><thead><tr>$(($columns | ForEach-Object { "<th>$(& $enc $_)</th>" }) -join '')</tr></thead>
<tbody>
$($body -join "`n")
</tbody></table></body></html>
"@
                Set-Content -Path $Path -Value $html -Encoding utf8
            }
        }

        Write-InfraLog -Level Info -Message "Wrote $($rows.Count) row(s) to $Path"
        if ($PassThru) { Get-Item -Path $Path }
    }
}
