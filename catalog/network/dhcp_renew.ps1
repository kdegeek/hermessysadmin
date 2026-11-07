<# hermes-catalog
id: network.dhcp_renew
title: Renew DHCP lease
category: Network
description: Renews the IPv4 DHCP lease on every DHCP-enabled adapter of each workstation, like ipconfig /renew. Normally the address stays the same, but if the DHCP server hands out a different one the management connection to that computer drops, so it is high risk. Refuses servers and domain controllers, and skips adapters with a static address. The preview shows each adapter's current address and lease.
module: inbox:CimCmdlets
target: endpoint
tier: H
preview: plan
destructive: false
columns: [host, adapter, before, after, result]
tags: [dhcp, renew, ipconfig, lease, ip address, release, network]
source: In-box CIM (Win32_OperatingSystem ProductType, Win32_NetworkAdapterConfiguration RenewDHCPLease)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
            $ErrorActionPreference = 'Stop'
            $productType = [int](Get-CimInstance Win32_OperatingSystem).ProductType
            $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE AND DHCPEnabled = TRUE')
            if ($nics.Count -eq 0) { return [pscustomobject]@{ adapter = $null; before = $null; lease_expires = $null; workstation = ($productType -eq 1) } }
            foreach ($n in $nics) {
                $exp = $null
                if ($n.DHCPLeaseExpires) { $exp = ([datetime]$n.DHCPLeaseExpires).ToUniversalTime().ToString('o') }
                [pscustomobject]@{ adapter = "$($n.Description)"; before = (@($n.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', '); lease_expires = $exp; workstation = ($productType -eq 1) }
            }
        }
        $cur = @{}
        foreach ($r in $read.items) {
            if (-not $cur.ContainsKey($r['host'])) { $cur[$r['host']] = @() }
            $cur[$r['host']] += ,@{ adapter = $r['adapter']; address = $r['before']; lease_expires = $r['lease_expires'] }
        }
        $changes = @(foreach ($r in $read.items) {
            if (-not $r['workstation']) { "$($r['host']): refused, not a workstation (servers and domain controllers are never renewed)" }
            elseif ($null -eq $r['adapter']) { "$($r['host']): nothing to do, no DHCP-enabled adapter" }
            else { "$($r['host']): renew the DHCP lease on $($r['adapter']) (now $($r['before']), lease expires $($r['lease_expires']))" }
        })
        return @{ summary = "Renew DHCP leases on $($targets.Count) computer(s); the connection to a computer drops if its address changes"
                  changes = @($changes) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        if ([int](Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {
            throw "Refusing to renew DHCP on $env:COMPUTERNAME`: it is a server or domain controller."
        }
        foreach ($n in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE AND DHCPEnabled = TRUE')) {
            $before = (@($n.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', ')
            $rv = Invoke-CimMethod -InputObject $n -MethodName RenewDHCPLease
            $after = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "Index = $([int]$n.Index)"
            [pscustomobject]@{
                adapter = "$($n.Description)"; before = $before
                after = (@($after.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', ')
                result = $(if ([int]$rv.ReturnValue -eq 0) { 'renewed' } else { "failed (code $([int]$rv.ReturnValue))" })
            }
        }
    }
}
