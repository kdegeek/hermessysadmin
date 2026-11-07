<# hermes-catalog
id: security.smb_signing
title: SMB signing, encryption and SMB1 client
category: Security posture
description: Whether the SMB server and client require signing, whether the server encrypts all shares, whether the SMB1 client driver (mrxsmb10) is still enabled and whether insecure guest logons are allowed. Signing not required on a server leaves it open to NTLM relay.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, server_signing_required, client_signing_required, server_encrypt_data, smb1_client, insecure_guest_logons]
tags: [smb, signing, smb signing, ntlm relay, smb encryption, smb1 client, mrxsmb10, guest]
source: In-box SmbShare (Get-SmbServerConfiguration, Get-SmbClientConfiguration) and registry (mrxsmb10, LanmanWorkstation)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $srv = Get-SmbServerConfiguration
        $cli = Get-SmbClientConfiguration
        $smb1c = 'not installed'
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10' -ErrorAction SilentlyContinue
        if ($k -and $null -ne $k.Start) { $smb1c = $(if ([int]$k.Start -eq 4) { 'disabled' } else { 'enabled' }) }
        $guest = $null
        $w = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -ErrorAction SilentlyContinue
        $wp = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -ErrorAction SilentlyContinue
        if ($wp -and $null -ne $wp.AllowInsecureGuestAuth) { $guest = ([int]$wp.AllowInsecureGuestAuth -eq 1) }
        elseif ($w -and $null -ne $w.AllowInsecureGuestAuth) { $guest = ([int]$w.AllowInsecureGuestAuth -eq 1) }
        [pscustomobject]@{
            server_signing_required = [bool]$srv.RequireSecuritySignature
            client_signing_required = [bool]$cli.RequireSecuritySignature
            server_encrypt_data     = [bool]$srv.EncryptData
            smb1_client             = $smb1c
            insecure_guest_logons   = $guest
        }
    }
}
