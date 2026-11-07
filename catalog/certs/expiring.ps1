<# hermes-catalog
id: certs.expiring
title: Expiring machine certificates
category: Certificates
description: Certificates in the computer's Personal store that expire within the given number of days (already expired ones are included with negative days_left).
module: inbox:Microsoft.PowerShell.Security
target: endpoint
tier: R
columns: [host, subject, thumbprint, not_after, days_left, issuer]
tags: [certificates, expiry, expiring, expired, tls, pki, cert]
source: In-box Cert:\LocalMachine\My
params:
  - {name: Days, type: integer, default: 30, minimum: 1, maximum: 3650, description: Report certificates that expire within this many days.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Days = 30)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Days) -Script {
        param($d)
        $ErrorActionPreference = 'Stop'
        $now = Get-Date
        $limit = $now.AddDays($d)
        foreach ($c in @(Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.NotAfter -lt $limit } | Sort-Object NotAfter | Select-Object -First 200)) {
            [pscustomobject]@{
                subject = "$($c.Subject)"; thumbprint = "$($c.Thumbprint)"; not_after = $c.NotAfter.ToUniversalTime().ToString('o')
                days_left = [int][math]::Floor(($c.NotAfter - $now).TotalDays); issuer = "$($c.Issuer)"
            }
        }
    }
}
