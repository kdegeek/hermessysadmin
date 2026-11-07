<# hermes-catalog
id: sessions.find_user
title: Find where a user is signed in
category: Users & sessions
description: Sessions of one user on the chosen computers (every enabled computer when none are given, up to 200), read with quser, with session name, ID, state, idle time and logon time. quser shows at most 20 characters of a user name, so longer names are matched on their first 20 characters. Computers that cannot be reached are listed under errors.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, user, session, id, state, idle, logon]
tags: [where is user logged on, find user, sessions, logged on, quser, signed in, locate user]
source: In-box quser.exe
params:
  - {name: User, type: string, required: true, description: "The user's sAMAccountName without the domain, for example jsmith."}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$User)
Invoke-Op {
    if ($User -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') { throw "InvalidArguments: User must be a sAMAccountName (letters, digits, '.', '_' or '-', up to 64 characters, no domain)" }
    $want = $User.ToLowerInvariant()
    if ($want.Length -gt 20) { $want = $want.Substring(0, 20) }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    $fan = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($want) -Script {
        param($w)
        # quser writes "No User exists" to stderr and exits 1 when nobody is logged on; that means zero rows.
        $lines = @(& { $ErrorActionPreference = 'Continue'; quser 2>$null })
        foreach ($line in $lines) {
            if ("$line" -match '^\s*>?(\S+)\s+(?:(\S+)\s+)?(\d+)\s+(\S+)\s+(\S+)\s+(.+?)\s*$') {
                $name = $Matches[1]
                $n = $name.ToLowerInvariant()
                if ($n.Length -gt 20) { $n = $n.Substring(0, 20) }
                if ($n -ne $w) { continue }
                [pscustomobject]@{ user = $name; session = "$($Matches[2])"; id = [int]$Matches[3]; state = $Matches[4]; idle = $Matches[5]; logon = $Matches[6] }
            }
        }
    }
    @{ items = @($fan.items | Select-Object -First 500); errors = $fan.errors
       summary = @{ user = $User; total = @($fan.items).Count; truncated = (@($fan.items).Count -gt 500)
                    computers_with_sessions = @($fan.items | ForEach-Object { $_['host'] } | Sort-Object -Unique).Count
                    hosts = $fan.summary.hosts; reached = ($fan.summary.hosts - $fan.summary.failed); failed = $fan.summary.failed } }
}
