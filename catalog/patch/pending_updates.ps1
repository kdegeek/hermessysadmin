<# hermes-catalog
id: patch.pending_updates
title: Pending Windows updates
category: Patching
description: Updates that are not installed and not hidden, from the Windows Update Agent. Search only; nothing is downloaded or installed. Some builds deny the search over remoting and report that per computer.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, title, kb, severity, size_mb, reboot]
tags: [updates, patches, pending, missing, windows update, wsus, kb]
source: In-box Windows Update Agent COM API (search only)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
        } catch {
            $m = "$($_.Exception.Message)"
            if ($m -match '0x80070005|Access is denied' -or $_.Exception.HResult -eq -2147024891) {
                throw 'Windows Update search was denied over remoting (0x80070005); this build does not allow the COM searcher from a remote session.'
            }
            throw
        }
        $rows = @(foreach ($u in $found.Updates) {
            $kbs = @($u.KBArticleIDs | ForEach-Object { "KB$_" })
            [pscustomobject]@{
                title = $(if ("$($u.Title)".Length -gt 300) { "$($u.Title)".Substring(0, 300) } else { "$($u.Title)" })
                kb = ($kbs -join ', '); severity = "$($u.MsrcSeverity)"
                size_mb = [math]::Round(([double]$u.MaxDownloadSize) / 1MB, 1)
                reboot = ([int]$u.InstallationBehavior.RebootBehavior -ne 0)
            }
        })
        $rows | Select-Object -First 200
    }
}
