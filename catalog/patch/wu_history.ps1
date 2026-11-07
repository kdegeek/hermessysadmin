<# hermes-catalog
id: patch.wu_history
title: Windows Update history
category: Patching
description: Recent Windows Update history per computer (date, KB, title, result and whether it was an install or uninstall) from the Windows Update Agent.
module: inbox:WindowsUpdateAgent
target: endpoint
tier: R
columns: [host, date, kb, title, result, operation]
tags: [update history, patches, installed updates, kb, failed updates, windows update]
source: In-box Windows Update Agent COM API (QueryHistory)
params:
  - {name: Last, type: integer, default: 20, minimum: 1, maximum: 200, description: Number of most recent history entries per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Last = 20)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Last) -Script {
        param($last)
        $ErrorActionPreference = 'Stop'
        try {
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $total = [int]$searcher.GetTotalHistoryCount()
            $entries = @()
            if ($total -gt 0) { $entries = @($searcher.QueryHistory(0, [math]::Min($last, $total))) }
        } catch {
            if ("$($_.Exception.Message)" -match '0x80070005|Access is denied' -or $_.Exception.HResult -eq -2147024891) {
                throw 'Windows Update history was denied over remoting (0x80070005); this build does not allow the COM searcher from a remote session.'
            }
            throw
        }
        $results = @{ 1 = 'in_progress'; 2 = 'succeeded'; 3 = 'succeeded_with_errors'; 4 = 'failed'; 5 = 'aborted' }
        $ops = @{ 1 = 'install'; 2 = 'uninstall' }
        foreach ($h in $entries) {
            $t = "$($h.Title)"
            $kb = $null
            if ($t -match '(KB\d{6,8})') { $kb = $Matches[1] }
            $rc = [int]$h.ResultCode; $op = [int]$h.Operation
            [pscustomobject]@{
                date = $(if ($h.Date) { ([datetime]$h.Date).ToUniversalTime().ToString('o') } else { $null })
                kb = $kb
                title = $t.Substring(0, [math]::Min(300, $t.Length))
                result = $(if ($results.ContainsKey($rc)) { $results[$rc] } else { "$rc" })
                operation = $(if ($ops.ContainsKey($op)) { $ops[$op] } else { "$op" })
            }
        }
    }
}
