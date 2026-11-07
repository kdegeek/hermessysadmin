<# hermes-catalog
id: security.name_resolution
title: LLMNR, NetBIOS, mDNS and WPAD exposure
category: Security posture
description: Multicast and broadcast name resolution that tools such as Responder abuse to capture NTLM hashes. Shows whether LLMNR is turned off by policy, how many IP-enabled adapters still allow NetBIOS over TCP/IP (setting 0 follows DHCP, which usually means on), whether mDNS is turned off and whether WPAD auto-discovery is turned off.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, llmnr, netbios_adapters_on, ip_adapters, mdns, wpad_service, wpad_disabled]
tags: [llmnr, netbios, nbt-ns, mdns, wpad, responder, name resolution, multicast, poisoning]
source: In-box registry (DNSClient policy, Dnscache, WinHttp) and CIM (Win32_NetworkAdapterConfiguration, Win32_Service)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $llmnr = 'on (default)'
        $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -ErrorAction SilentlyContinue
        if ($p -and $null -ne $p.EnableMulticast) { $llmnr = $(if ([int]$p.EnableMulticast -eq 0) { 'off (policy)' } else { 'on (policy)' }) }
        $ad = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True')
        $nbOn = @($ad | Where-Object { $null -eq $_.TcpipNetbiosOptions -or [int]$_.TcpipNetbiosOptions -ne 2 }).Count
        $mdns = 'on (default)'
        $d = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -ErrorAction SilentlyContinue
        if ($d -and $null -ne $d.EnableMDNS) { $mdns = $(if ([int]$d.EnableMDNS -eq 0) { 'off' } else { 'on' }) }
        $svc = Get-CimInstance Win32_Service -Filter "Name = 'WinHttpAutoProxySvc'"
        $wsvc = 'not installed'
        if ($svc) { $wsvc = "$($svc.StartMode) / $($svc.State)" }
        $wpadOff = $false
        $wh = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp' -ErrorAction SilentlyContinue
        if ($wh -and $null -ne $wh.DisableWpad -and [int]$wh.DisableWpad -eq 1) { $wpadOff = $true }
        if ($svc -and "$($svc.StartMode)" -eq 'Disabled') { $wpadOff = $true }
        [pscustomobject]@{ llmnr = $llmnr; netbios_adapters_on = $nbOn; ip_adapters = $ad.Count; mdns = $mdns; wpad_service = $wsvc; wpad_disabled = $wpadOff }
    }
}
