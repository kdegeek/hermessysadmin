<# hermes-catalog
id: endpoint.page_file
title: Page file configuration and use
category: Endpoint health
description: Page file location, whether Windows manages it automatically, configured initial and maximum size (0 means system-managed for that file), allocated size, current and peak use in MB, and installed RAM. A configured file that only appears after a restart shows blank usage; a computer with no page file returns one row with a blank path.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, path, automatic, initial_mb, max_mb, allocated_mb, current_mb, peak_mb, ram_gb]
tags: [page file, pagefile, virtual memory, swap, commit, memory]
source: In-box CIM (Win32_ComputerSystem, Win32_PageFileSetting, Win32_PageFileUsage)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $cs = Get-CimInstance Win32_ComputerSystem
        $auto = [bool]$cs.AutomaticManagedPagefile
        $ram = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1)
        $settings = @(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
        $usage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        $paths = @(@($usage | ForEach-Object { "$($_.Name)" }) + @($settings | ForEach-Object { "$($_.Name)" }) | Where-Object { $_ } | Sort-Object -Unique)
        if ($paths.Count -eq 0) {
            return [pscustomobject]@{ path = ''; automatic = $auto; initial_mb = $null; max_mb = $null; allocated_mb = $null; current_mb = $null; peak_mb = $null; ram_gb = $ram }
        }
        foreach ($p in $paths) {
            $s = $settings | Where-Object { "$($_.Name)" -eq $p } | Select-Object -First 1
            $u = $usage | Where-Object { "$($_.Name)" -eq $p } | Select-Object -First 1
            [pscustomobject]@{ path = $p; automatic = $auto
                               initial_mb = if ($s) { [int]$s.InitialSize } else { $null }; max_mb = if ($s) { [int]$s.MaximumSize } else { $null }
                               allocated_mb = if ($u) { [int]$u.AllocatedBaseSize } else { $null }
                               current_mb = if ($u) { [int]$u.CurrentUsage } else { $null }; peak_mb = if ($u) { [int]$u.PeakUsage } else { $null }
                               ram_gb = $ram }
        }
    }
}
