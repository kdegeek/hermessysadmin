<# hermes-catalog
id: remote.logoff_session
title: Log off a session
category: Users & sessions
description: Logs off one session by ID on each computer. Unsaved work in that session is lost.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, user, session_id, logged_off]
tags: [logoff, sessions, users]
source: In-box quser.exe and logoff.exe
params:
  - {name: SessionId, type: integer, required: true, minimum: 0, description: Session ID from remote_sessions.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$SessionId, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($SessionId) -Script {
        param($id)
        foreach ($line in @(quser 2>$null)) {
            if ("$line" -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+\S+') {
                if ([int]$Matches[3] -eq $id) { [pscustomobject]@{ user = $Matches[1] } }
            }
        }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['user'] }
        return @{ summary = "Log off session $SessionId on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): log off session $SessionId ($($_['user']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($SessionId) -Script {
        param($id)
        $ErrorActionPreference = 'Stop'
        $user = ''
        $rows = & { $ErrorActionPreference = 'Continue'; & quser.exe 2>$null }
        foreach ($line in @($rows)) {
            if ("$line" -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+\S+') {
                if ([int]$Matches[3] -eq $id) { $user = $Matches[1] }
            }
        }
        if (-not $user) { throw "No session $id on this computer." }
        $code = & { $ErrorActionPreference = 'Continue'; & logoff.exe $id 2>$null | Out-Null; [int]$LASTEXITCODE }
        [pscustomobject]@{ user = $user; session_id = $id; logged_off = ($code -eq 0) }
    }
}
