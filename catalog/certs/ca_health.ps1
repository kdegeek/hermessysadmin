<# hermes-catalog
id: certs.ca_health
title: Enterprise CA availability and expiry
category: Certificates
description: Every enterprise certification authority published in Active Directory, with its host, whether its request interface answers a ping (certutil -ping, the same check as the CA console), its CA certificate expiry and days left, whether that certificate is in the NTAuth store (needed for smart card and certificate logon), and how many templates it publishes. A ping that fails means enrollment and autoenrollment against that CA fail too.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [ca, host, ping_ok, not_after, days_left, in_ntauth, templates]
tags: [adcs, ca, certification authority, pki, certutil ping, ca certificate, expiry, ntauth, enrollment]
source: In-box ActiveDirectory (Get-ADObject on Enrollment Services and NTAuthCertificates) and certutil -config -ping
#>
param()
Invoke-Op {
    $cfg = (Get-ADRootDSE).configurationNamingContext
    $pks = "CN=Public Key Services,CN=Services,$cfg"
    $ntauth = @{}
    try {
        $nt = Get-ADObject -Identity "CN=NTAuthCertificates,$pks" -Properties cACertificate
        foreach ($b in @($nt.cACertificate)) { $ntauth[(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$b)).Thumbprint] = $true }
    } catch { }
    $errs = @()
    $rows = @()
    $now = Get-Date
    foreach ($ca in @(Get-ADObject -SearchBase "CN=Enrollment Services,$pks" -SearchScope OneLevel -LDAPFilter '(objectClass=pKIEnrollmentService)' -Properties dNSHostName, cACertificate, certificateTemplates | Sort-Object Name)) {
        $name = "$($ca.Name)"
        $hostName = "$($ca.dNSHostName)"
        $newest = $null
        foreach ($b in @($ca.cACertificate)) {
            try {
                $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (,[byte[]]$b)
                if (-not $newest -or $x.NotAfter -gt $newest.NotAfter) { $newest = $x }
            } catch { }
        }
        $ping = $null
        if ($hostName -cmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,252}\z' -and $name -cmatch '\A[^"\\\x00-\x1f]{1,64}\z') {
            $config = "$hostName\$name"
            $null = & { $ErrorActionPreference = 'Continue'; certutil.exe -config $config -ping 2>$null }
            $ping = ($LASTEXITCODE -eq 0)
        } else {
            $errs += @{ host = $hostName; message = "$name`: host or CA name has unexpected characters; ping skipped" }
        }
        $rows += @{
            ca = $name; host = $hostName; ping_ok = $ping
            not_after = $(if ($newest) { $newest.NotAfter.ToUniversalTime().ToString('o') } else { $null })
            days_left = $(if ($newest) { [int][math]::Floor(($newest.NotAfter - $now).TotalDays) } else { $null })
            in_ntauth = $(if ($newest) { $ntauth.ContainsKey($newest.Thumbprint) } else { $null })
            templates = @($ca.certificateTemplates).Count
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); unreachable = @($rows | Where-Object { $_.ping_ok -eq $false }).Count } }
}
