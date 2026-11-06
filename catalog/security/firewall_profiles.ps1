<# hermes-catalog
id: security.firewall_profiles
title: Windows Firewall profiles
category: Security posture
description: Whether the Domain, Private and Public firewall profiles are enabled and their default inbound and outbound actions.
module: inbox:NetSecurity
target: endpoint
tier: R
columns: [host, profile, enabled, inbound_default, outbound_default]
tags: [firewall, profile, domain, private, public, inbound, outbound]
source: In-box NetSecurity (Get-NetFirewallProfile)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($p in @(Get-NetFirewallProfile)) {
            [pscustomobject]@{ profile = "$($p.Name)"; enabled = ("$($p.Enabled)" -eq 'True'); inbound_default = "$($p.DefaultInboundAction)"; outbound_default = "$($p.DefaultOutboundAction)" }
        }
    }
}
