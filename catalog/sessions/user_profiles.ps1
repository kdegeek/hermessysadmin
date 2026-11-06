<# hermes-catalog
id: sessions.user_profiles
title: User profiles
category: Users & sessions
description: Local user profiles with last use and size on disk; MinDaysUnused finds stale profiles. Size is blank for profiles not measured within the 40 second per-host budget.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, user, last_use, size_mb]
tags: [profiles, stale, disk, users, cleanup]
source: In-box CIM (Win32_UserProfile)
params:
  - {name: MinDaysUnused, type: integer, default: 0, minimum: 0, maximum: 3650, description: Only profiles unused for at least this many days.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MinDaysUnused = 0)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinDaysUnused) -Script {
        param($minDays)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cutoff = (Get-Date).AddDays(-$minDays)
        $profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath } |
            Where-Object { $minDays -le 0 -or -not $_.LastUseTime -or $_.LastUseTime -lt $cutoff } | Select-Object -First 200)
        # Pass 1: identity and last use for every profile, so rows exist even if sizing runs out of time.
        $rows = foreach ($pr in $profiles) {
            $sid = "$($pr.SID)"
            $user = try { ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { $sid }
            [pscustomobject]@{ user = $user
                               last_use = if ($pr.LastUseTime) { $pr.LastUseTime.ToUniversalTime().ToString('o') } else { '' }
                               size_mb = $null; _path = "$($pr.LocalPath)" }
        }
        # Pass 2: size each profile with a manual walk that stops when the 40 s budget is spent.
        foreach ($row in @($rows)) {
            if ($clock.Elapsed.TotalSeconds -ge 40 -or -not (Test-Path -LiteralPath $row._path)) { continue }
            $bytes = [int64]0; $complete = $true
            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push($row._path)
            while ($stack.Count -gt 0) {
                if ($clock.Elapsed.TotalSeconds -ge 40) { $complete = $false; break }
                $dir = $stack.Pop()
                foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) { $bytes += $f.Length }
                foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -Attributes '!ReparsePoint' -ErrorAction SilentlyContinue)) { $stack.Push($d.FullName) }
            }
            if ($complete) { $row.size_mb = [math]::Round($bytes / 1MB, 1) }
        }
        $rows | Select-Object user, last_use, size_mb
    }
}
