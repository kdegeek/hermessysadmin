<# hermes-catalog
id: maint.time_resync
title: Resynchronise the clock
category: Maintenance
description: Asks the Windows Time service on each computer to resynchronise now with its configured time source (w32tm /resync). It does not change the time source or any configuration. Computers where W32Time is not running are reported and left alone.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, source, before, after, exit_code, output]
tags: [time, ntp, w32tm, resync, clock skew, kerberos, time sync]
source: In-box w32tm /resync and w32tm /query /status
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    # $apply = $false only reads the current state; $true also resyncs. Status fields are parsed from English output.
    $script = {
        param($apply)
        $ErrorActionPreference = 'Continue'
        function Get-SyncState {
            $s = @{ source = ''; last = '' }
            foreach ($line in @(w32tm.exe /query /status 2>$null)) {
                if ("$line" -match '^\s*Source:\s*(.+?)\s*$') { $s.source = $Matches[1] }
                elseif ("$line" -match '^\s*Last Successful Sync Time:\s*(.+?)\s*$') { $s.last = $Matches[1] }
            }
            return $s
        }
        $svc = Get-Service -Name W32Time -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') {
            $state = if ($svc) { "$($svc.Status)" } else { 'NotInstalled' }
            return [pscustomobject]@{ source = ''; before = ''; after = ''; exit_code = $null; output = "W32Time is $state; not resynced"; running = $false }
        }
        $b = Get-SyncState
        if (-not $apply) { return [pscustomobject]@{ source = $b.source; before = $b.last; after = ''; exit_code = $null; output = ''; running = $true } }
        $out = @(w32tm.exe /resync 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
        $code = $LASTEXITCODE
        $a = Get-SyncState
        $msg = ($out -join ' ').Trim()
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
        [pscustomobject]@{ source = $a.source; before = $b.last; after = $a.last; exit_code = $code; output = $msg; running = $true }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $script
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ source = $r['source']; last_sync = $r['before']; running = $r['running'] } }
        return @{ summary = "Resynchronise the clock on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { if ($_['running']) { "$($_['host']): resync with $($_['source']) (last sync $($_['before']))" } else { "$($_['host']): skipped - $($_['output'])" } }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $script
}
