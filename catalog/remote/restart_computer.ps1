<# hermes-catalog
id: remote.restart_computer
title: Restart computers
category: Maintenance
description: Restarts each computer after a delay with a reason shown to users. Logged-on users lose unsaved work. The reason is at most 512 characters on one line.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: H
preview: plan
columns: [host, restart_scheduled]
tags: [restart, reboot, shutdown, maintenance]
source: In-box shutdown.exe and quser.exe
params:
  - {name: Reason, type: string, required: true, description: Reason shown to users. At most 512 characters and no line breaks.}
  - {name: DelaySeconds, type: integer, default: 300, minimum: 0, maximum: 315360000, description: Seconds to wait before restarting.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Reason, [int]$DelaySeconds = 300, [switch]$Preview)
Invoke-Op {
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'Reason is required.' }
    if ($Reason.Length -gt 512) { throw 'Reason must be 512 characters or fewer.' }
    if ($Reason -match '[\r\n]') { throw 'Reason must not contain line breaks.' }
    $text = $Reason.Replace('"', "'").TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Reason is empty after trimming trailing backslashes.' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            $users = @()
            foreach ($line in @(quser 2>$null)) {
                if ("$line" -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+\S+') { $users += $Matches[1] }
            }
            [pscustomobject]@{ users = $users }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @($r['users']) }
        return @{ summary = "Restart $($targets.Count) computer(s) in $DelaySeconds seconds"
                  changes = @($read.items | ForEach-Object { "$($_['host']): restart in $DelaySeconds seconds (logged on: $(@($_['users']) -join ', '))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($text, $DelaySeconds) -Script {
        param($why, $delay)
        $ErrorActionPreference = 'Stop'
        & shutdown.exe /r /t $delay /c $why /d p:0:0
        if ($LASTEXITCODE -ne 0) { throw "shutdown.exe exited with code $LASTEXITCODE" }
        [pscustomobject]@{ restart_scheduled = $true }
    }
}
