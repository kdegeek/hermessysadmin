<# hermes-catalog
id: certs.root_store
title: Trusted root store problems
category: Certificates
description: Certificates in the computer's Trusted Root store (including roots pushed by Group Policy or AD) that are expired, signed with MD5 or MD2, have an RSA key under 2048 bits, or are not self-signed, plus every certificate in the Untrusted (Disallowed) store. Show all lists every root instead. Only public certificate data is read. Up to 300 rows per computer.
module: inbox:Microsoft.PowerShell.Security
target: endpoint
tier: R
columns: [host, store, subject, thumbprint, not_after, problem]
tags: [certificates, root ca, trusted root, expired root, untrusted, disallowed, md5, weak key, pki, rogue root]
source: In-box Cert:\LocalMachine\Root and Cert:\LocalMachine\Disallowed
params:
  - {name: Show, type: string, default: problems, enum: [problems, all], description: problems lists only flagged roots and the Disallowed store; all lists every root.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Show = 'problems')
Invoke-Op {
    if (@('problems', 'all') -cnotcontains $Show) { throw 'InvalidArguments: Show must be problems or all' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Show) -Script {
        param($mode)
        $ErrorActionPreference = 'Stop'
        $now = Get-Date
        $n = 0
        foreach ($c in @(Get-ChildItem -Path 'Cert:\LocalMachine\Root' | Sort-Object Subject)) {
            $p = @()
            if ($c.NotAfter -lt $now) { $p += 'expired' }
            $alg = "$($c.SignatureAlgorithm.FriendlyName)"
            if ($alg -match '^(md5|md2)') { $p += "weak signature ($alg)" }
            $bits = $null
            if ("$($c.PublicKey.Oid.Value)" -eq '1.2.840.113549.1.1.1') { try { $bits = [int]$c.PublicKey.Key.KeySize } catch { $bits = $null } }
            if ($bits -and $bits -lt 2048) { $p += "RSA $bits-bit key" }
            if ($c.Subject -ne $c.Issuer) { $p += 'not self-signed' }
            if ($mode -eq 'problems' -and $p.Count -eq 0) { continue }
            if ($n -ge 300) { return }
            $n++
            [pscustomobject]@{ store = 'Root'; subject = "$($c.Subject)"; thumbprint = "$($c.Thumbprint)"; not_after = $c.NotAfter.ToUniversalTime().ToString('o'); problem = ($p -join ', ') }
        }
        foreach ($c in @(Get-ChildItem -Path 'Cert:\LocalMachine\Disallowed' -ErrorAction SilentlyContinue | Sort-Object Subject)) {
            if ($n -ge 300) { return }
            $n++
            [pscustomobject]@{ store = 'Disallowed'; subject = "$($c.Subject)"; thumbprint = "$($c.Thumbprint)"; not_after = $c.NotAfter.ToUniversalTime().ToString('o'); problem = 'explicitly untrusted' }
        }
    }
}
