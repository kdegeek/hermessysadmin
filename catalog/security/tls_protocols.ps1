<# hermes-catalog
id: security.tls_protocols
title: TLS and SSL protocol settings
category: Security posture
description: SCHANNEL settings for SSL 3.0, TLS 1.0, 1.1 and 1.2 as server and client; shows default when the registry has no override.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, protocol, server, client]
tags: [tls, ssl, schannel, protocols, tls 1.0, tls 1.2, crypto]
source: In-box registry (SCHANNEL Protocols)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Continue'
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
        function Get-State([string]$Path) {
            $k = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
            if (-not $k) { return 'default' }
            $en = $k.Enabled; $dbd = $k.DisabledByDefault
            if ($null -ne $en -and [int]$en -eq 0) { return 'disabled' }
            if ($null -ne $dbd -and [int]$dbd -eq 1) { return 'disabled by default' }
            if ($null -ne $en) { return 'enabled' }
            return 'default'
        }
        foreach ($p in @('SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2')) {
            [pscustomobject]@{ protocol = $p; server = (Get-State "$base\$p\Server"); client = (Get-State "$base\$p\Client") }
        }
    }
}
