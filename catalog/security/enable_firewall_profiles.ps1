<# hermes-catalog
id: security.enable_firewall_profiles
title: Turn on all firewall profiles
category: Security posture
description: Turns on every Windows Firewall profile (Domain, Private, Public) that is off in the local store. Never turns a profile off and does not change rules or default actions. Before changing anything it checks every profile it would turn on that is in use by a network connection, and refuses the whole computer unless an enabled inbound rule there admits the WinRM port this session uses from every connected WinRM client, and the Remote Desktop port when Remote Desktop is on, with no matching block rule, so the change cannot cut management or RDP. Profiles that Group Policy keeps off are left alone and named. Undo with Set-NetFirewallProfile -Enabled False.
module: inbox:NetSecurity
target: endpoint
tier: W
preview: plan
columns: [host, before, after, result]
tags: [firewall, enable firewall, firewall profile, domain, private, public, hardening]
source: In-box NetSecurity (Get-NetFirewallProfile, Get-NetFirewallRule and filters, Get-NetConnectionProfile, Get-NetTCPConnection, Set-NetFirewallProfile)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        function Get-State { (@(Get-NetFirewallProfile -PolicyStore ActiveStore | ForEach-Object { "$($_.Name)=$(if ("$($_.Enabled)" -eq 'True') { 'on' } else { 'off' })" }) -join ', ') }
        $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
        $before = Get-State
        $off = @($profiles | Where-Object { "$($_.Enabled)" -ne 'True' } | ForEach-Object { "$($_.Name)" })
        if ($off.Count -eq 0) { return [pscustomobject]@{ before = $before; after = $before; result = 'all profiles already on' } }
        $gpOff = @()
        try {
            foreach ($g in @(Get-NetFirewallProfile -PolicyStore RSOP -ErrorAction Stop)) {
                if ("$($g.Enabled)" -eq 'False' -and $off -contains "$($g.Name)") { $gpOff += "$($g.Name)" }
            }
        } catch { $gpOff = @() }
        $toOn = @($off | Where-Object { $gpOff -notcontains $_ })
        $gpNote = ''
        if ($gpOff.Count -gt 0) { $gpNote = " (Group Policy keeps $($gpOff -join ', ') off)" }
        if ($toOn.Count -eq 0) { return [pscustomobject]@{ before = $before; after = $before; result = "nothing to change$gpNote" } }

        # Which of those profiles carry live traffic now. Unknown -> treat every one as live.
        $active = @()
        foreach ($c in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
            switch ("$($c.NetworkCategory)") { 'DomainAuthenticated' { $active += 'Domain' } 'Private' { $active += 'Private' } 'Public' { $active += 'Public' } }
        }
        $live = @($toOn | Where-Object { $active.Count -eq 0 -or $active -contains $_ })

        # What must stay reachable: the WinRM port(s) in use and their clients, plus RDP when it is on.
        $wsman = @(Get-NetTCPConnection -State Established -LocalPort 5985, 5986 -ErrorAction SilentlyContinue)
        $need = @()
        $wports = @($wsman | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
        if ($wports.Count -eq 0) { $wports = @(5985) }
        $wcallers = @($wsman | ForEach-Object { "$($_.RemoteAddress)" -replace '^::ffff:', '' } | Sort-Object -Unique)
        foreach ($p in $wports) { $need += , @('WinRM', $p, $wcallers, @('Any', 'System')) }
        $deny = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
        $tsPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        if ($tsPol -and $null -ne $tsPol.fDenyTSConnections) { $deny = $tsPol.fDenyTSConnections }
        if ($null -ne $deny -and [int]$deny -eq 0) {
            $rport = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').PortNumber
            $rcallers = @(Get-NetTCPConnection -State Established -LocalPort $rport -ErrorAction SilentlyContinue | ForEach-Object { "$($_.RemoteAddress)" -replace '^::ffff:', '' } | Sort-Object -Unique)
            $need += , @('Remote Desktop', $rport, $rcallers, @('Any', '*svchost.exe'))
        }

        $problems = @()
        if ($live.Count -gt 0) {
            $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound)
            $ports = @{}; foreach ($f in @(Get-NetFirewallPortFilter -PolicyStore ActiveStore)) { $ports["$($f.InstanceID)"] = $f }
            $addrs = @{}; foreach ($f in @(Get-NetFirewallAddressFilter -PolicyStore ActiveStore)) { $addrs["$($f.InstanceID)"] = $f }
            $apps = @{}; foreach ($f in @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore)) { $apps["$($f.InstanceID)"] = $f }
            function Test-Port($list, [int]$port) {
                foreach ($x in @($list)) {
                    $t = "$x"
                    if ($t -eq 'Any') { return $true }
                    if ($t -match '^\d+$' -and [int]$t -eq $port) { return $true }
                    if ($t -match '^(\d+)-(\d+)$' -and $port -ge [int]$Matches[1] -and $port -le [int]$Matches[2]) { return $true }
                }
                return $false
            }
            function Test-Rule($r, [string]$prof, [int]$port, $callers, $programs, [bool]$allCallers) {
                $rp = "$($r.Profile)"
                if ($rp -ne 'Any' -and (@($rp -split ',\s*') -notcontains $prof)) { return $false }
                $id = "$($r.InstanceID)"
                $pf = $ports[$id]; $af = $addrs[$id]; $ap = $apps[$id]
                if (-not $pf -or -not $af) { return $false }
                if (@('TCP', '6', 'Any') -notcontains "$($pf.Protocol)") { return $false }
                if (-not (Test-Port $pf.LocalPort $port)) { return $false }
                $prog = 'Any'; if ($ap) { $prog = "$($ap.Program)" }
                $progOk = $false
                foreach ($pp in $programs) { if ($prog -like $pp) { $progOk = $true } }
                if (-not $progOk) { return $false }
                $ra = @($af.RemoteAddress | ForEach-Object { "$_" })
                if ($ra -contains 'Any') { return $true }
                if (@($callers).Count -eq 0) { return $allCallers }
                foreach ($c in @($callers)) {
                    if ($allCallers -and $ra -notcontains $c) { return $false }
                    if (-not $allCallers -and $ra -contains $c) { return $true }
                }
                return $allCallers
            }
            foreach ($prof in $live) {
                $pobj = $profiles | Where-Object { "$($_.Name)" -eq $prof } | Select-Object -First 1
                if ("$($pobj.AllowInboundRules)" -eq 'False') { $problems += "$prof blocks all inbound rules (AllowInboundRules False)"; continue }
                if ("$($pobj.DefaultInboundAction)" -eq 'Allow') { continue }
                foreach ($n in $need) {
                    $label = $n[0]; $port = [int]$n[1]; $callers = @($n[2]); $progs = @($n[3])
                    $allowed = @($rules | Where-Object { "$($_.Action)" -eq 'Allow' -and (Test-Rule $_ $prof $port $callers $progs $true) })
                    $blocked = @($rules | Where-Object { "$($_.Action)" -eq 'Block' -and (Test-Rule $_ $prof $port $callers @('*') $false) })
                    if ($allowed.Count -eq 0) { $problems += "$prof has no enabled inbound rule admitting $label (TCP $port) from $(if ($callers.Count) { $callers -join ', ' } else { 'its clients' })" }
                    elseif ($blocked.Count -gt 0) { $problems += "$prof has a block rule on $label (TCP $port): $($blocked[0].DisplayName)" }
                }
            }
        }
        if ($problems.Count -gt 0) { return [pscustomobject]@{ before = $before; after = $before; result = "refused: $($problems -join '; ')$gpNote" } }
        if (-not $apply) { return [pscustomobject]@{ before = $before; after = $before; result = "will turn on $($toOn -join ', ')$gpNote" } }
        Set-NetFirewallProfile -Profile $toOn -Enabled True
        [pscustomobject]@{ before = $before; after = (Get-State); result = "turned on $($toOn -join ', ')$gpNote" }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Turn on every Windows Firewall profile on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['before']) -> $($_['result'])" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
