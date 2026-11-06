<# hermes-catalog
id: remote.open_rdp_firewall
title: Open the Remote Desktop firewall rules
category: Remote access
description: Enables the Remote Desktop firewall rule group so RDP connections can reach the computer.
module: inbox:NetSecurity
target: endpoint
tier: W
preview: plan
columns: [host, enabled_before, enabled_after]
tags: [rdp, firewall, remote desktop]
source: In-box NetSecurity (Enable-NetFirewallRule)
params: []
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            [pscustomobject]@{ enabled = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Where-Object { $_.Enabled -eq 'True' }).Count; total = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop').Count }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ enabled = $r['enabled']; total = $r['total'] } }
        return @{ summary = "Enable the Remote Desktop firewall rules on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['enabled']) of $($_['total']) rules enabled -> all enabled" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $before = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Where-Object { $_.Enabled -eq 'True' }).Count
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        [pscustomobject]@{ enabled_before = $before; enabled_after = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' | Where-Object { $_.Enabled -eq 'True' }).Count }
    }
}
