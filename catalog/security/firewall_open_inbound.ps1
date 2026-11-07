<# hermes-catalog
id: security.firewall_open_inbound
title: Inbound firewall rules open to any address
category: Security posture
description: Enabled inbound Allow rules in the effective policy (local and Group Policy) whose remote address is Any, with protocol, local ports, program and profile. Windows built-in rule groups are left out unless IncludeBuiltIn is true, so the list shows rules added by people and applications. At most 200 rules per computer.
module: inbox:NetSecurity
target: endpoint
tier: R
columns: [host, rule, profile, protocol, local_ports, program, policy_source]
tags: [firewall, inbound, open ports, firewall rules, any address, exposure, attack surface]
source: In-box NetSecurity (Get-NetFirewallRule, Get-NetFirewallPortFilter, Get-NetFirewallAddressFilter, Get-NetFirewallApplicationFilter on the ActiveStore)
params:
  - {name: IncludeBuiltIn, type: boolean, default: false, description: Also list the Windows built-in rule groups.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$IncludeBuiltIn = $false)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($IncludeBuiltIn) -Script {
        param($builtIn)
        $ErrorActionPreference = 'Stop'
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow)
        if (-not $builtIn) { $rules = @($rules | Where-Object { "$($_.Group)" -notlike '@*' }) }
        if ($rules.Count -eq 0) { return }
        $ports = @{}; foreach ($f in @(Get-NetFirewallPortFilter -PolicyStore ActiveStore)) { $ports["$($f.InstanceID)"] = $f }
        $addrs = @{}; foreach ($f in @(Get-NetFirewallAddressFilter -PolicyStore ActiveStore)) { $addrs["$($f.InstanceID)"] = $f }
        $apps = @{}; foreach ($f in @(Get-NetFirewallApplicationFilter -PolicyStore ActiveStore)) { $apps["$($f.InstanceID)"] = $f }
        $n = 0
        foreach ($r in $rules) {
            $id = "$($r.InstanceID)"
            $a = $addrs[$id]
            if (-not $a -or @($a.RemoteAddress) -notcontains 'Any') { continue }
            $p = $ports[$id]
            $app = $apps[$id]
            $prog = $null
            if ($app -and "$($app.Program)" -ne 'Any') { $prog = "$($app.Program)" }
            [pscustomobject]@{
                rule = "$($r.DisplayName)"; profile = "$($r.Profile)"
                protocol = $(if ($p) { "$($p.Protocol)" } else { $null })
                local_ports = $(if ($p) { (@($p.LocalPort) -join ',') } else { $null })
                program = $prog; policy_source = "$($r.PolicyStoreSourceType)"
            }
            $n++
            if ($n -ge 200) { break }
        }
    }
}
