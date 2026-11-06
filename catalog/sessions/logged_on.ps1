<# hermes-catalog
id: sessions.logged_on
title: Logged-on users
category: Users & sessions
description: Interactive and remote desktop sessions per computer with state, idle time and logon time.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, user, session, id, state, idle, logon]
tags: [sessions, logged on, who, users, rdp, quser]
source: In-box quser.exe
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        # quser writes "No User exists" to stderr and exits 1 when nobody is logged on; that means zero rows.
        $lines = @(& { $ErrorActionPreference = 'Continue'; quser 2>$null })
        foreach ($line in $lines) {
            if ("$line" -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+(\S+)\s+(\S+)\s+(.+?)\s*$') {
                [pscustomobject]@{ user = $Matches[1]; session = "$($Matches[2])"; id = [int]$Matches[3]; state = $Matches[4]; idle = $Matches[5]; logon = $Matches[6] }
            }
        }
    }
}
