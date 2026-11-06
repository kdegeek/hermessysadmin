<# hermes-catalog
id: remote.lock_workstation
title: Lock active sessions
category: Users & sessions
description: Disconnects each active session with tsdiscon. The session is disconnected and left locked at the sign-in screen and the user's programs keep running.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, user, session_id, disconnected]
tags: [lock, disconnect, sessions, security]
source: In-box quser.exe and tsdiscon.exe
params: []
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
# quser prints a session name (console, rdp-tcp#N) only for connected sessions; disconnected rows omit it.
# Matching on that column avoids the localized state word (Active/Aktiv/Actif).
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            foreach ($line in @(quser 2>$null)) {
                if ("$line" -match '^\s*>?(\S+)\s+([^\s\d]\S*)\s+(\d+)\s+\S+') { [pscustomobject]@{ user = $Matches[1]; session_id = [int]$Matches[3] } }
            }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @($read.items | Where-Object { $_['host'] -eq $r['host'] } | ForEach-Object { $_['session_id'] }) }
        return @{ summary = "Disconnect $(@($read.items).Count) active session(s) on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): disconnect session $($_['session_id']) ($($_['user']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($line in @(quser 2>$null)) {
            if ("$line" -match '^\s*>?(\S+)\s+([^\s\d]\S*)\s+(\d+)\s+\S+') {
                $user = $Matches[1]; $id = [int]$Matches[3]
                & tsdiscon.exe $id
                [pscustomobject]@{ user = $user; session_id = $id; disconnected = ($LASTEXITCODE -eq 0) }
            }
        }
    }
}
