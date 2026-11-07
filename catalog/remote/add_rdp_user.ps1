<# hermes-catalog
id: remote.add_rdp_user
title: Add Remote Desktop users
category: Remote access
description: Adds users or groups to the local Remote Desktop Users group. Members already present are skipped.
module: inbox:Microsoft.PowerShell.LocalAccounts
target: endpoint
tier: W
preview: plan
columns: [host, added, skipped]
tags: [rdp, remote desktop users, access]
source: In-box LocalAccounts (Add-LocalGroupMember on S-1-5-32-555)
params:
  - {name: Members, type: array, required: true, description: Users or groups to add as DOMAIN\name or name.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string[]]$Members = @(), [switch]$Preview)
Invoke-Op {
    $list = @($Members | Where-Object { $_ })
    if ($list.Count -eq 0) { throw 'Members is required.' }
    foreach ($m in $list) {
        if ($m -notmatch '^[A-Za-z0-9 ._\\@-]+$') { throw "Member '$m' contains characters that are not allowed." }
    }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $names = @()
        try {
            $names = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" })
        } catch {
            # Get-LocalGroupMember fails on orphaned domain SIDs in 5.1; fall back to ADSI by the group's translated name.
            $gn = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-555').Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
            foreach ($mem in @(([ADSI]"WinNT://./$gn,group").Invoke('Members'))) {
                $names += (([ADSI]$mem).Path -replace '^WinNT://', '').Replace('/', '\')
            }
        }
        [pscustomobject]@{ members = $names }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @($r['members']) }
        return @{ summary = "Add $($list.Count) member(s) to Remote Desktop Users on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): add $($list -join ', ') (current members: $(@($_['members']) -join ', '))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @(, $list) -Script {
        param($names)
        $ErrorActionPreference = 'Stop'
        # Resolve every name first: if any fails, this computer reports the error and nobody is added.
        $resolved = @()
        foreach ($m in @($names)) {
            try { $resolved += [pscustomobject]@{ name = $m; sid = (New-Object System.Security.Principal.NTAccount($m)).Translate([System.Security.Principal.SecurityIdentifier]).Value } }
            catch { throw "Cannot resolve '$m' to an account on this computer; no members were added." }
        }
        $have = @()
        try {
            $have = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.SID.Value)" })
        } catch {
            # Orphaned SIDs break Get-LocalGroupMember in 5.1; read the members' SIDs through ADSI instead.
            $gn = (New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-555').Translate([System.Security.Principal.NTAccount]).Value.Split('\')[1]
            foreach ($mem in @(([ADSI]"WinNT://./$gn,group").Invoke('Members'))) {
                $have += (New-Object System.Security.Principal.SecurityIdentifier(([ADSI]$mem).objectSid.Value, 0)).Value
            }
        }
        $added = @(); $skipped = @()
        foreach ($r in $resolved) {
            if ($have -contains $r.sid) { $skipped += $r.name; continue }
            Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $r.name
            $added += $r.name
            $have += $r.sid
        }
        [pscustomobject]@{ added = $added; skipped = $skipped }
    }
}
