<# hermes-catalog
id: network.proxy_settings
title: Machine proxy settings
category: Network
description: The WinHTTP proxy (what services, Windows Update and many agents use) and the machine-wide Internet Settings proxy policy on each computer. winhttp is 'direct' when no WinHTTP proxy is set. Per-user browser proxy settings (HKCU) are not read. Values that hold credentials are never read. Query strings and fragments are stripped from PAC (AutoConfigURL) addresses and user:password@ parts from proxy addresses, because some vendors put tenant keys or tokens there.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, winhttp, winhttp_proxy, winhttp_bypass, per_user_policy, machine_proxy_enable, machine_proxy, machine_pac]
tags: [proxy, winhttp, netsh winhttp, pac, autoconfig, internet settings, wpad, web proxy]
source: In-box registry (HKLM Connections WinHttpSettings, Internet Settings and their policy keys)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        # WinHttpSettings layout: [0..3] struct version, [4..7] counter, [8..11] flags (bit 2 = proxy set),
        # [12..15] proxy length, proxy (ASCII), then 4-byte bypass length and the bypass list (ASCII).
        $mode = 'direct'; $proxy = $null; $bypass = $null
        $conn = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
        $blob = $null
        try { $blob = [byte[]](Get-ItemProperty -Path $conn -Name WinHttpSettings -ErrorAction Stop).WinHttpSettings } catch { $blob = $null }
        if ($blob -and $blob.Length -ge 16) {
            $flags = [BitConverter]::ToInt32($blob, 8)
            $plen = [BitConverter]::ToInt32($blob, 12)
            if ($plen -gt 0 -and (16 + $plen) -le $blob.Length) {
                $proxy = [Text.Encoding]::ASCII.GetString($blob, 16, $plen)
                $off = 16 + $plen
                if (($off + 4) -le $blob.Length) {
                    $blen = [BitConverter]::ToInt32($blob, $off)
                    if ($blen -gt 0 -and ($off + 4 + $blen) -le $blob.Length) { $bypass = [Text.Encoding]::ASCII.GetString($blob, $off + 4, $blen) }
                }
            }
            if (($flags -band 2) -ne 0 -and $proxy) { $mode = 'proxy' } elseif ($proxy) { $mode = 'unknown' }
        }
        $perUser = $null
        try { $perUser = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxySettingsPerUser -ErrorAction Stop).ProxySettingsPerUser } catch { $perUser = $null }
        $is = $null
        try { $is = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { $is = $null }
        # Strip user:password@ from proxy addresses and the query string / fragment from PAC URLs (they can carry keys).
        function Get-Clean([string]$v, [bool]$isUrl) {
            if (-not $v) { return $v }
            $v = $v -replace '(?<=://)[^/@\s;]*@', '' -replace '(?<=[=;\s]|\A)[^/@\s;=]*:[^/@\s;=]*@', ''
            if ($isUrl) { $v = $v -replace '[?#].*\z', '' }
            return $v
        }
        if ($proxy) { $proxy = Get-Clean $proxy $false }
        $enable = $null; $mproxy = $null; $pac = $null
        if ($is) {
            if ($null -ne $is.ProxyEnable) { $enable = ([int]$is.ProxyEnable -eq 1) }
            if ($is.ProxyServer) { $mproxy = Get-Clean "$($is.ProxyServer)" $false }
            if ($is.AutoConfigURL) { $pac = Get-Clean "$($is.AutoConfigURL)" $true }
        }
        [pscustomobject]@{
            winhttp = $mode; winhttp_proxy = $proxy; winhttp_bypass = $bypass
            per_user_policy = $(if ($null -eq $perUser) { $null } else { [int]$perUser })
            machine_proxy_enable = $enable; machine_proxy = $mproxy; machine_pac = $pac
        }
    }
}
