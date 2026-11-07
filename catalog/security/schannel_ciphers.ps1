<# hermes-catalog
id: security.schannel_ciphers
title: SCHANNEL ciphers, hashes and .NET strong crypto
category: Security posture
description: SCHANNEL cipher and hash overrides (NULL, DES, RC2, RC4, Triple DES, AES, MD5, SHA), the minimum Diffie-Hellman key size, whether a cipher suite order is set by policy and how many suites it lists, and whether .NET Framework 4 apps (64-bit and 32-bit) are forced to use strong crypto and the system TLS versions. default means the registry has no override and Windows decides. Protocol versions are in security.tls_protocols.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, kind, name, state]
tags: [schannel, ciphers, rc4, 3des, des, md5, cipher suites, tls, .net strong crypto, schusestrongcrypto, sweet32]
source: In-box registry through .NET Microsoft.Win32.Registry (SCHANNEL Ciphers, Hashes and KeyExchangeAlgorithms, Cryptography policy, .NETFramework v4.0.30319)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        # Cipher key names contain '/', which the registry provider treats as a path separator, so read through .NET.
        $hklm = [Microsoft.Win32.Registry]::LocalMachine
        function Get-Val([string]$Path, [string]$Name) {
            $k = $hklm.OpenSubKey($Path, $false)
            if ($null -eq $k) { return $null }
            try { return $k.GetValue($Name, $null) } finally { $k.Close() }
        }
        function Get-EnabledState([string]$Path) {
            $v = Get-Val $Path 'Enabled'
            if ($null -eq $v) { return 'default' }
            if ([int64]$v -eq 0) { return 'disabled' }
            return 'enabled'
        }
        $sc = 'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
        foreach ($c in @('NULL', 'DES 56/56', 'RC2 40/128', 'RC2 56/128', 'RC2 128/128', 'RC4 40/128', 'RC4 56/128', 'RC4 64/128', 'RC4 128/128', 'Triple DES 168', 'AES 128/128', 'AES 256/256')) {
            [pscustomobject]@{ kind = 'cipher'; name = $c; state = (Get-EnabledState "$sc\Ciphers\$c") }
        }
        foreach ($h in @('MD5', 'SHA', 'SHA256', 'SHA384', 'SHA512')) {
            [pscustomobject]@{ kind = 'hash'; name = $h; state = (Get-EnabledState "$sc\Hashes\$h") }
        }
        $dh = Get-Val "$sc\KeyExchangeAlgorithms\Diffie-Hellman" 'ServerMinKeyBitLength'
        [pscustomobject]@{ kind = 'key exchange'; name = 'Diffie-Hellman server minimum bits'; state = $(if ($null -ne $dh) { "$dh" } else { 'default' }) }
        $fn = Get-Val 'SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' 'Functions'
        $order = 'default'
        if ($fn) {
            $list = @("$fn" -split ',' | Where-Object { $_.Trim() -ne '' })
            $weak = @($list | Where-Object { $_ -match 'RC4|3DES|_DES_|NULL|EXPORT|MD5' }).Count
            $order = "set by policy ($($list.Count) suites, $weak weak)"
        }
        [pscustomobject]@{ kind = 'cipher suites'; name = 'suite order policy'; state = $order }
        foreach ($nf in @(@('.NET 4 (64-bit)', 'SOFTWARE\Microsoft\.NETFramework\v4.0.30319'), @('.NET 4 (32-bit)', 'SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319'))) {
            $strong = Get-Val $nf[1] 'SchUseStrongCrypto'
            $sys = Get-Val $nf[1] 'SystemDefaultTlsVersions'
            $txt = "SchUseStrongCrypto=$(if ($null -ne $strong) { $strong } else { 'not set' }), SystemDefaultTlsVersions=$(if ($null -ne $sys) { $sys } else { 'not set' })"
            [pscustomobject]@{ kind = 'dotnet'; name = $nf[0]; state = $txt }
        }
    }
}
