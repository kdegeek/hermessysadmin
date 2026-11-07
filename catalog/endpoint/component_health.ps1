<# hermes-catalog
id: endpoint.component_health
title: Component store health
category: Endpoint health
description: Runs DISM /CheckHealth, which only reports whether Windows has already recorded component store (WinSxS) corruption - Healthy, Repairable or NotRepairable. It does not scan or repair and changes nothing apart from writing to the DISM log. A full scan (ScanHealth / sfc) takes many minutes and is not run here. It fails while another servicing operation is running.
module: inbox:Dism
target: endpoint
tier: R
columns: [host, state, exit_code, detail]
tags: [dism, checkhealth, component store, winsxs, corruption, sfc, servicing, system files]
source: In-box dism.exe /Online /Cleanup-Image /CheckHealth
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Continue'
        $out = @(dism.exe /English /Online /Cleanup-Image /CheckHealth 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        $text = $out -join "`n"
        $state = 'Unknown'
        if ($text -match 'No component store corruption detected') { $state = 'Healthy' }
        elseif ($text -match 'cannot be repaired') { $state = 'NotRepairable' }
        elseif ($text -match 'component store is repairable') { $state = 'Repairable' }
        $detail = (@($out | Where-Object { "$_".Trim() }) | Select-Object -Last 1)
        $detail = "$detail".Trim()
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        [pscustomobject]@{ state = $state; exit_code = $code; detail = $detail }
    }
}
