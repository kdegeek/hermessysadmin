<# hermes-catalog
id: maint.remove_stale_profiles
title: Remove stale user profiles
category: Maintenance
description: Deletes local user profiles (the profile folder and its registry entry, the same as System Properties > User Profiles > Delete) that have not been used for at least MinDaysUnused days (minimum 30). Never touches loaded profiles, special or service profiles, profiles without a recorded last-use time, profiles outside the Users folder, the built-in Administrator, the account running this action or any user listed in Exclude. At most Max profiles per computer, oldest first. Any files saved only in those profiles are lost. Last-use times can be refreshed by backup or antivirus software, which makes profiles look newer, never older.
module: inbox:CimCmdlets
target: endpoint
tier: H
preview: plan
destructive: true
columns: [host, user, last_use, path, removed, error]
tags: [user profile, delete profile, stale profiles, disk space, cleanup, delprof]
source: In-box CIM (Win32_UserProfile, Remove-CimInstance)
params:
  - {name: MinDaysUnused, type: integer, default: 90, minimum: 30, maximum: 3650, description: Only profiles unused for at least this many days.}
  - name: Exclude
    type: array
    default: []
    description: User names to keep, as user or DOMAIN\user.
  - {name: Max, type: integer, default: 25, minimum: 1, maximum: 200, description: Most profiles to remove per computer.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$MinDaysUnused = 90, [string[]]$Exclude = @(), [int]$Max = 25, [switch]$Preview)
Invoke-Op {
    if ($MinDaysUnused -lt 30) { throw 'InvalidArguments: MinDaysUnused must be at least 30' }
    if ($Max -lt 1 -or $Max -gt 200) { throw 'InvalidArguments: Max must be 1 to 200' }
    $keep = @($Exclude | Where-Object { "$_" -ne '' })
    foreach ($u in $keep) {
        if ("$u" -cnotmatch '\A([A-Za-z0-9][A-Za-z0-9._-]{0,14}\\)?[A-Za-z0-9 ._$@-]{1,104}\z') { throw "InvalidArguments: Exclude entry '$u' must be a user name such as jsmith or CONTOSO\jsmith" }
    }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    # $delete = $false only lists the profiles that would go; $true removes them.
    $script = {
        param($minDays, $keep, $max, $delete)
        $cutoff = (Get-Date).AddDays(-$minDays)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $usersDir = [Environment]::ExpandEnvironmentVariables("$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop).ProfilesDirectory)").TrimEnd('\')
        $keepSet = @($keep | ForEach-Object { "$_".ToLowerInvariant() })
        $candidates = foreach ($p in @(Get-CimInstance Win32_UserProfile -ErrorAction Stop)) {
            $sid = "$($p.SID)"
            if ($p.Special -or $p.Loaded -or -not $p.LocalPath -or -not $p.LastUseTime) { continue }
            if ($p.LastUseTime -ge $cutoff) { continue }
            if ($sid -notlike 'S-1-5-21-*' -and $sid -notlike 'S-1-12-1-*') { continue }
            if ($sid -eq $me -or $sid -match '-500\z') { continue }
            $path = "$($p.LocalPath)".TrimEnd('\')
            if ((Split-Path -Path $path -Parent) -ne $usersDir) { continue }
            $user = $sid
            try { $user = ([Security.Principal.SecurityIdentifier]$sid).Translate([Security.Principal.NTAccount]).Value } catch { $user = $sid }
            $leaf = ($user -split '\\')[-1]
            if ($keepSet -contains $user.ToLowerInvariant() -or $keepSet -contains $leaf.ToLowerInvariant() -or $keepSet -contains (Split-Path -Path $path -Leaf).ToLowerInvariant()) { continue }
            [pscustomobject]@{ p = $p; user = $user; last = $p.LastUseTime; path = $path }
        }
        foreach ($c in @($candidates | Sort-Object last | Select-Object -First $max)) {
            $removed = $null; $err = ''
            if ($delete) {
                try { Remove-CimInstance -InputObject $c.p -ErrorAction Stop; $removed = $true }
                catch { $removed = $false; $err = "$($_.Exception.Message)"; if ($err.Length -gt 200) { $err = $err.Substring(0, 200) } }
            }
            [pscustomobject]@{ user = $c.user; last_use = $c.last.ToUniversalTime().ToString('o'); path = $c.path; removed = $removed; error = $err }
        }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinDaysUnused, $keep, $Max, $false) -Script $script
        $cur = @{}
        foreach ($r in $read.items) { if (-not $cur.ContainsKey($r['host'])) { $cur[$r['host']] = @() }; $cur[$r['host']] += "$($r['user']) (last used $($r['last_use']))" }
        return @{ summary = "Delete $($read.items.Count) user profile(s) unused for $MinDaysUnused+ day(s) on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): delete profile $($_['user']) at $($_['path']) (last used $($_['last_use']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($MinDaysUnused, $keep, $Max, $true) -Script $script
}
