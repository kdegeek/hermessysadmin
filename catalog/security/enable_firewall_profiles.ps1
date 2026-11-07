<# hermes-catalog
id: security.enable_firewall_profiles
title: Turn on all firewall profiles
category: Security posture
description: Turns on every Windows Firewall profile (Domain, Private, Public) that is off in the local store, on workstations only - servers and domain controllers are refused on the computer itself. Never turns a profile off and does not change rules or default actions. Before changing anything it checks every profile it would turn on, whether or not a network uses it now, and refuses the whole computer when an enabled inbound block rule in that profile touches WinRM (TCP 5985/5986) or, when Remote Desktop is on, its port or 3389, whatever the rule's address scope; or when no enabled inbound allow rule admits the WinRM port this session uses (and the Remote Desktop port) from every connected client with no IPsec, user, interface or local-address restriction. Allow rules scoped by a keyword such as LocalSubnet are not counted. Profiles that Group Policy keeps off are left alone and named. Undo with Set-NetFirewallProfile -Enabled False.
module: inbox:NetSecurity
target: endpoint
tier: W
preview: plan
columns: [host, before, after, result]
tags: [firewall, enable firewall, firewall profile, domain, private, public, hardening]
source: In-box NetSecurity (Get-NetFirewallProfile, Get-NetFirewallRule and its port, address, application, service, security, interface and interface-type filters, Get-NetTCPConnection, Set-NetFirewallProfile) and CIM Win32_OperatingSystem
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        if ([int](Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {
            return [pscustomobject]@{ before = $null; after = $null; result = 'refused: not a workstation (servers and domain controllers are never changed)' }
        }
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

        # What must stay reachable: the WinRM port(s) in use and their clients, plus RDP when it is on.
        $wsman = @(Get-NetTCPConnection -State Established -LocalPort 5985, 5986 -ErrorAction SilentlyContinue)
        $need = @()
        $wports = @($wsman | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique)
        if ($wports.Count -eq 0) { $wports = @(5985) }
        $wcallers = @($wsman | ForEach-Object { "$($_.RemoteAddress)" -replace '^::ffff:', '' } | Sort-Object -Unique)
        foreach ($p in $wports) { $need += , @('WinRM', $p, $wcallers, @('Any', 'System'), @('Any')) }
        # Block rules are checked on both WinRM ports whatever port is in use now, for any program that can own
        # the listener (WinRM runs in System, RDP in svchost); an app-specific block rule cannot touch them.
        $blockPorts = @(@(5985, 5986) | ForEach-Object { , @('WinRM', $_, @('Any', 'System')) })
        $deny = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
        $tsPol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        if ($tsPol -and $null -ne $tsPol.fDenyTSConnections) { $deny = $tsPol.fDenyTSConnections }
        if ($null -ne $deny -and [int]$deny -eq 0) {
            $rport = [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').PortNumber
            $rcallers = @(Get-NetTCPConnection -State Established -LocalPort $rport -ErrorAction SilentlyContinue | ForEach-Object { "$($_.RemoteAddress)" -replace '^::ffff:', '' } | Sort-Object -Unique)
            $need += , @('Remote Desktop', $rport, $rcallers, @('Any', '*svchost.exe'), @('Any', 'termservice'))
            $blockPorts += , @('Remote Desktop', $rport, @('Any', '*svchost.exe'))
            if ($rport -ne 3389) { $blockPorts += , @('Remote Desktop', 3389, @('Any', '*svchost.exe')) }
        }

        # Every profile that would be turned on is checked, in use now or not: a network can be classed
        # differently after the next reboot (a DC or server landing on Public is a known case).
        $problems = @()
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound)
        $ports = @{}; foreach ($f in @(Get-NetFirewallPortFilter -PolicyStore ActiveStore)) { $ports["$($f.InstanceID)"] = $f }
        $addrs = @{}; foreach ($f in @(Get-NetFirewallAddressFilter -PolicyStore ActiveStore)) { $addrs["$($f.InstanceID)"] = $f }
        $apps = @{}; foreach ($f in @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore)) { $apps["$($f.InstanceID)"] = $f }
        $svcs = @{}; foreach ($f in @(Get-NetFirewallServiceFilter -PolicyStore ActiveStore)) { $svcs["$($f.InstanceID)"] = $f }
        $secs = @{}; foreach ($f in @(Get-NetFirewallSecurityFilter -PolicyStore ActiveStore)) { $secs["$($f.InstanceID)"] = $f }
        $itypes = @{}; foreach ($f in @(Get-NetFirewallInterfaceTypeFilter -PolicyStore ActiveStore)) { $itypes["$($f.InstanceID)"] = $f }
        $ifaces = @{}; foreach ($f in @(Get-NetFirewallInterfaceFilter -PolicyStore ActiveStore)) { $ifaces["$($f.InstanceID)"] = $f }
        function Test-Port($list, [int]$port) {
            foreach ($x in @($list)) {
                $t = "$x"
                if ($t -eq 'Any') { return $true }
                if ($t -match '^\d+$' -and [int]$t -eq $port) { return $true }
                if ($t -match '^(\d+)-(\d+)$' -and $port -ge [int]$Matches[1] -and $port -le [int]$Matches[2]) { return $true }
            }
            return $false
        }
        function ConvertTo-V4([string]$ip) {
            $a = $null
            if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$a)) { return $null }
            if ($a.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
            $b = $a.GetAddressBytes()
            return ([long]$b[0] * 16777216) + ([long]$b[1] * 65536) + ([long]$b[2] * 256) + [long]$b[3]
        }
        # True only when the allow rule's remote address list certainly contains the caller.
        function Test-Covers($list, [string]$caller) {
            $c = ConvertTo-V4 $caller
            foreach ($x in @($list)) {
                $t = "$x"
                if ($t -eq 'Any') { return $true }
                if ($t -eq $caller) { return $true }
                if ($null -eq $c) { continue }
                if ($t -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
                    $net = ConvertTo-V4 $Matches[1]; $bits = [int]$Matches[2]
                    if ($null -ne $net -and $bits -ge 0 -and $bits -le 32) {
                        $size = [long][math]::Pow(2, 32 - $bits)
                        if ([math]::Floor($net / $size) -eq [math]::Floor($c / $size)) { return $true }
                    }
                } elseif ($t -match '^(\d+\.\d+\.\d+\.\d+)/(\d+\.\d+\.\d+\.\d+)$') {
                    $net = ConvertTo-V4 $Matches[1]; $mask = ConvertTo-V4 $Matches[2]
                    if ($null -ne $net -and $null -ne $mask -and (([long]$net -band [long]$mask) -eq ([long]$c -band [long]$mask))) { return $true }
                } elseif ($t -match '^(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)$') {
                    $lo = ConvertTo-V4 $Matches[1]; $hi = ConvertTo-V4 $Matches[2]
                    if ($null -ne $lo -and $null -ne $hi -and $c -ge $lo -and $c -le $hi) { return $true }
                }
                # Keywords (LocalSubnet, Intranet, DefaultGateway, ...) are not trusted to cover the caller.
            }
            return $false
        }
        function Test-Scope($r, [string]$prof, [int]$port, $programs) {
            $rp = "$($r.Profile)"
            if ($rp -ne 'Any' -and (@($rp -split ',\s*') -notcontains $prof)) { return $false }
            $pf = $ports["$($r.InstanceID)"]; $ap = $apps["$($r.InstanceID)"]
            if (-not $pf) { return $false }
            if (@('TCP', '6', 'Any') -notcontains "$($pf.Protocol)") { return $false }
            if (-not (Test-Port $pf.LocalPort $port)) { return $false }
            $prog = 'Any'; if ($ap) { $prog = "$($ap.Program)" }
            foreach ($pp in $programs) { if ($prog -like $pp) { return $true } }
            return $false
        }
        # An allow rule counts only when nothing beyond port, program and remote address narrows it, and the
        # remote address covers every current client.
        function Test-Allow($r, [string]$prof, [int]$port, $callers, $programs, $services) {
            if (-not (Test-Scope $r $prof $port $programs)) { return $false }
            $id = "$($r.InstanceID)"
            $af = $addrs[$id]; $sv = $svcs[$id]; $sc = $secs[$id]; $it = $itypes[$id]; $ifc = $ifaces[$id]
            if (-not $af) { return $false }
            if (@($af.LocalAddress | Where-Object { "$_" -ne 'Any' }).Count -gt 0) { return $false }
            if ($sv -and $services -notcontains "$($sv.Service)") { return $false }
            if ($sc) {
                if ("$($sc.Authentication)" -ne 'NotRequired' -or "$($sc.Encryption)" -ne 'NotRequired') { return $false }
                foreach ($u in @($sc.LocalUser, $sc.RemoteUser, $sc.RemoteMachine)) { if ("$u" -and "$u" -ne 'Any') { return $false } }
            }
            if ($it -and "$($it.InterfaceType)" -ne 'Any') { return $false }
            if ($ifc -and @($ifc.InterfaceAlias | Where-Object { "$_" -ne 'Any' }).Count -gt 0) { return $false }
            $ra = @($af.RemoteAddress | ForEach-Object { "$_" })
            if ($ra -contains 'Any') { return $true }
            if (@($callers).Count -eq 0) { return $false }
            foreach ($c in @($callers)) { if (-not (Test-Covers $ra $c)) { return $false } }
            return $true
        }
        foreach ($prof in $toOn) {
            $pobj = $profiles | Where-Object { "$($_.Name)" -eq $prof } | Select-Object -First 1
            if ("$($pobj.AllowInboundRules)" -eq 'False') { $problems += "$prof blocks all inbound rules (AllowInboundRules False)"; continue }
            # Any enabled inbound block rule on a management port fails closed, whatever its address scope.
            foreach ($bp in $blockPorts) {
                $blocked = @($rules | Where-Object { "$($_.Action)" -eq 'Block' -and (Test-Scope $_ $prof ([int]$bp[1]) @($bp[2])) })
                if ($blocked.Count -gt 0) { $problems += "$prof has a block rule on $($bp[0]) (TCP $($bp[1])): $($blocked[0].DisplayName)" }
            }
            if ("$($pobj.DefaultInboundAction)" -eq 'Allow') { continue }
            foreach ($n in $need) {
                $label = $n[0]; $port = [int]$n[1]; $callers = @($n[2]); $progs = @($n[3]); $svcOk = @($n[4])
                $allowed = @($rules | Where-Object { "$($_.Action)" -eq 'Allow' -and (Test-Allow $_ $prof $port $callers $progs $svcOk) })
                if ($allowed.Count -eq 0) { $problems += "$prof has no unrestricted enabled inbound rule admitting $label (TCP $port) from $(if ($callers.Count) { $callers -join ', ' } else { 'its clients' })" }
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
