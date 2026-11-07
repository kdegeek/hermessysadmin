<# hermes-catalog
id: remote.rdp_listener
title: Remote Desktop listener security and certificate
category: Remote access
description: The RDP-Tcp listener's port, security layer (RDP, Negotiate or TLS), minimum encryption level and the certificate it presents, with subject, expiry, days left and whether it is self-signed. Group Policy values for security layer and encryption level win over the listener's own. Certificates are public; nothing private is read. NLA is in security.rdp_nla.
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, port, security_layer, encryption_level, cert_subject, cert_not_after, cert_days_left, cert_self_signed, cert_thumbprint, source]
tags: [rdp, remote desktop, certificate, tls, security layer, encryption level, rdp certificate expiry, 3389]
source: In-box registry (RDP-Tcp, Terminal Services policy), CIM (root\cimv2\TerminalServices Win32_TSGeneralSetting) and the certificate provider
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $tcp = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        $layer = $tcp.SecurityLayer; $enc = $tcp.MinEncryptionLevel; $source = 'local'
        if ($pol -and $null -ne $pol.SecurityLayer) { $layer = $pol.SecurityLayer; $source = 'policy' }
        if ($pol -and $null -ne $pol.MinEncryptionLevel) { $enc = $pol.MinEncryptionLevel; $source = 'policy' }
        $layerMap = @{ 0 = 'RDP'; 1 = 'Negotiate'; 2 = 'TLS' }
        $encMap = @{ 1 = 'Low'; 2 = 'Client compatible'; 3 = 'High'; 4 = 'FIPS' }
        $ln = $null; if ($null -ne $layer) { $ln = $layerMap[[int]$layer]; if (-not $ln) { $ln = "value $layer" } }
        $en = $null; if ($null -ne $enc) { $en = $encMap[[int]$enc]; if (-not $en) { $en = "value $enc" } }
        $thumb = $null; $subj = $null; $after = $null; $days = $null; $self = $null
        try {
            $ts = Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName = 'RDP-Tcp'"
            if ($ts -and $ts.SSLCertificateSHA1Hash) { $thumb = "$($ts.SSLCertificateSHA1Hash)".ToUpperInvariant() }
        } catch { $thumb = $null }
        if ($thumb -and $thumb -cmatch '\A[0-9A-F]{40}\z') {
            $cert = $null
            foreach ($store in @('Cert:\LocalMachine\Remote Desktop', 'Cert:\LocalMachine\My')) {
                $c = Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
                if ($c) { $cert = $c; break }
            }
            if ($cert) {
                $subj = "$($cert.Subject)"
                $after = $cert.NotAfter.ToUniversalTime().ToString('o')
                $days = [int][math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
                $self = ("$($cert.Subject)" -eq "$($cert.Issuer)")
            }
        }
        [pscustomobject]@{
            port = $tcp.PortNumber; security_layer = $ln; encryption_level = $en
            cert_subject = $subj; cert_not_after = $after; cert_days_left = $days; cert_self_signed = $self; cert_thumbprint = $thumb; source = $source
        }
    }
}
