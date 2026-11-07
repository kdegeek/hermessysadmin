<# hermes-catalog
id: remote.winrm_listeners
title: WinRM listeners and service settings
category: Remote access
description: One row per WinRM listener with transport, address, port, host name, enabled state and certificate thumbprint (HTTPS), plus the service settings that matter for security on every row (unencrypted traffic allowed, Basic and CredSSP authentication) and the client TrustedHosts list (cut to 300 characters). Read-only; uses the local WS-Management configuration.
module: inbox:Microsoft.WSMan.Management
target: endpoint
tier: R
columns: [host, transport, address, port, hostname, enabled, cert_thumbprint, allow_unencrypted, basic_auth, credssp_auth, trusted_hosts]
tags: [winrm, wsman, powershell remoting, listener, https, 5985, 5986, basic auth, credssp, trustedhosts]
source: In-box Microsoft.WSMan.Management (Get-WSManInstance winrm/config/listener, winrm/config/service, winrm/config/client)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $svc = Get-WSManInstance -ResourceURI 'winrm/config/service'
        $cli = $null
        try { $cli = Get-WSManInstance -ResourceURI 'winrm/config/client' } catch { $cli = $null }
        $unenc = ("$($svc.AllowUnencrypted)" -eq 'true')
        $basic = ("$($svc.Auth.Basic)" -eq 'true')
        $credssp = ("$($svc.Auth.CredSSP)" -eq 'true')
        $th = $null
        if ($cli) {
            $th = "$($cli.TrustedHosts)"
            if ($th.Length -gt 300) { $th = $th.Substring(0, 300) }
        }
        foreach ($l in @(Get-WSManInstance -ResourceURI 'winrm/config/listener' -Enumerate)) {
            [pscustomobject]@{
                transport = "$($l.Transport)"; address = "$($l.Address)"; port = "$($l.Port)"; hostname = "$($l.Hostname)"
                enabled = ("$($l.Enabled)" -eq 'true'); cert_thumbprint = $(if ("$($l.CertificateThumbprint)" -ne '') { "$($l.CertificateThumbprint)" } else { $null })
                allow_unencrypted = $unenc; basic_auth = $basic; credssp_auth = $credssp; trusted_hosts = $th
            }
        }
    }
}
