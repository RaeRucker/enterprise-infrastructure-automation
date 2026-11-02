function Get-ServerHealth {
    <#
    .SYNOPSIS
        Read-only health audit of one or more Windows servers over CIM (WinRM).
    .DESCRIPTION
        Collects uptime, memory, fixed-disk free space, stopped automatic services,
        pending reboot reasons, and the most recent installed update. Each server gets
        an overall Status (Healthy / Warning / Critical / Unreachable) and a list of
        Findings that explain the status.

        Thresholds come from Get-InfraOpsConfig. An unreachable server produces a
        result object (Status = Unreachable) instead of terminating the run, so one bad
        host doesn't hide the results for the rest.
    .PARAMETER ComputerName
        Servers to audit. Accepts pipeline input (for example from Get-ADComputer).
    .PARAMETER Credential
        Optional credential. Omit to use the current identity (preferred: run as a
        least-privilege monitoring account).
    .EXAMPLE
        'SRV-APP01','SRV-SQL01' | Get-ServerHealth | Where-Object Status -ne 'Healthy'
    .EXAMPLE
        Get-ADComputer -Filter 'OperatingSystem -like "*Server*"' | Get-ServerHealth | Export-InfraReport -Path ./output/health.html
    .OUTPUTS
        InfraOps.ServerHealth
    .NOTES
        Requires: WinRM (TCP 5985/5986) to each server, and membership of the local
        "Remote Management Users" group plus WMI read rights, or local administrator.
    #>
    [CmdletBinding()]
    [OutputType('InfraOps.ServerHealth')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name', 'DNSHostName')]
        [ValidateNotNullOrEmpty()]
        [string[]] $ComputerName,

        [pscredential] $Credential
    )

    begin {
        $config = Get-InfraOpsConfig
        $t = $config.Thresholds
    }

    process {
        foreach ($computer in $ComputerName) {
            $findings = [System.Collections.Generic.List[string]]::new()
            $severity = 0   # 0 Healthy, 1 Warning, 2 Critical
            $session = $null

            try {
                $session = Open-InfraCimSession -ComputerName $computer -Credential $Credential
            }
            catch {
                Write-InfraLog -Level Warning -Message "Cannot connect to ${computer}: $($_.Exception.Message)" -Data @{ computer = $computer }
                [pscustomobject]@{
                    PSTypeName = 'InfraOps.ServerHealth'
                    ComputerName = $computer; Status = 'Unreachable'; Findings = @("Connection failed: $($_.Exception.Message)")
                    UptimeDays = $null; MemoryUsedPercent = $null; Disks = @(); StoppedAutoServices = @()
                    PendingReboot = @(); LastUpdateInstalled = $null; CollectedAt = (Get-Date)
                }
                continue
            }

            try {
                $os = Invoke-InfraCimQuery -CimSession $session -ClassName Win32_OperatingSystem
                $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
                $memUsed = [math]::Round(100 * (1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)), 1)

                if ($uptimeDays -ge $t.UptimeWarningDays) {
                    $findings.Add("Uptime $uptimeDays days (>= $($t.UptimeWarningDays)); updates may not be applied"); $severity = [math]::Max($severity, 1)
                }
                if ($memUsed -ge $t.MemoryWarningPercent) {
                    $findings.Add("Memory $memUsed% used (>= $($t.MemoryWarningPercent)%)"); $severity = [math]::Max($severity, 1)
                }

                $disks = foreach ($d in Invoke-InfraCimQuery -CimSession $session -ClassName Win32_LogicalDisk -Filter 'DriveType=3') {
                    if (-not $d.Size) { continue }
                    $freePct = [math]::Round(100 * $d.FreeSpace / $d.Size, 1)
                    if ($freePct -le $t.DiskCriticalFreePercent) {
                        $findings.Add("Disk $($d.DeviceID) $freePct% free (<= $($t.DiskCriticalFreePercent)%)"); $severity = 2
                    }
                    elseif ($freePct -le $t.DiskWarningFreePercent) {
                        $findings.Add("Disk $($d.DeviceID) $freePct% free (<= $($t.DiskWarningFreePercent)%)"); $severity = [math]::Max($severity, 1)
                    }
                    [pscustomobject]@{ Drive = $d.DeviceID; SizeGB = [math]::Round($d.Size / 1GB, 1); FreeGB = [math]::Round($d.FreeSpace / 1GB, 1); FreePercent = $freePct }
                }

                $stopped = @(Invoke-InfraCimQuery -CimSession $session -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
                    Where-Object { $_.Name -notin $config.ServicesIgnoredWhenStopped } |
                    ForEach-Object Name)
                if ($stopped.Count) {
                    $findings.Add("Automatic services not running: $($stopped -join ', ')"); $severity = [math]::Max($severity, 1)
                }

                $pending = @(Test-InfraPendingReboot -CimSession $session)
                if ($pending.Count) {
                    $findings.Add("Reboot pending: $($pending -join '; ')"); $severity = [math]::Max($severity, 1)
                }

                $lastUpdate = Invoke-InfraCimQuery -CimSession $session -ClassName Win32_QuickFixEngineering |
                    Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
                $lastUpdateDate = if ($lastUpdate) { [datetime]$lastUpdate.InstalledOn } else { $null }
                if (-not $lastUpdateDate -or ((Get-Date) - $lastUpdateDate).TotalDays -ge $t.PatchWarningDays) {
                    $findings.Add("No update installed in the last $($t.PatchWarningDays) days"); $severity = [math]::Max($severity, 1)
                }

                [pscustomobject]@{
                    PSTypeName          = 'InfraOps.ServerHealth'
                    ComputerName        = $computer
                    Status              = @('Healthy', 'Warning', 'Critical')[$severity]
                    Findings            = $findings.ToArray()
                    UptimeDays          = $uptimeDays
                    MemoryUsedPercent   = $memUsed
                    Disks               = @($disks)
                    StoppedAutoServices = $stopped
                    PendingReboot       = $pending
                    LastUpdateInstalled = $lastUpdateDate
                    CollectedAt         = (Get-Date)
                }
                Write-InfraLog -Level Info -Message "$computer status $(@('Healthy','Warning','Critical')[$severity])" -Data @{ computer = $computer; findings = $findings.Count }
            }
            catch {
                Write-InfraLog -Level Error -Message "Collection failed on ${computer}: $($_.Exception.Message)" -Data @{ computer = $computer }
                [pscustomobject]@{
                    PSTypeName = 'InfraOps.ServerHealth'
                    ComputerName = $computer; Status = 'Unreachable'; Findings = @("Collection failed: $($_.Exception.Message)")
                    UptimeDays = $null; MemoryUsedPercent = $null; Disks = @(); StoppedAutoServices = @()
                    PendingReboot = @(); LastUpdateInstalled = $null; CollectedAt = (Get-Date)
                }
            }
            finally {
                if ($session) { Close-InfraCimSession -CimSession $session }
            }
        }
    }
}
