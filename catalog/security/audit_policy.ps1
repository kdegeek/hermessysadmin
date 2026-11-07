<# hermes-catalog
id: security.audit_policy
title: Local audit policy
category: Security posture
description: The effective advanced audit policy (auditpol /get /category:* /r) as one row per subcategory, with Success, Failure or No Auditing. NotAuditedOnly keeps only subcategories set to No Auditing; it matches the English setting text, so on other display languages it may return nothing. At most 500 rows in total.
module: inbox:Microsoft.PowerShell.Utility
target: endpoint
tier: R
columns: [host, subcategory, setting, guid]
tags: [audit, audit policy, auditpol, advanced audit, logging, event log, security log, subcategory]
source: In-box auditpol.exe (/get /r, read-only) and ConvertFrom-Csv
params:
  - {name: NotAuditedOnly, type: boolean, default: false, description: Return only subcategories set to No Auditing.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$NotAuditedOnly = $false)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $fan = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($NotAuditedOnly) -Script {
        param($onlyNone)
        $ErrorActionPreference = 'Stop'
        $lines = @(& { $ErrorActionPreference = 'Continue'; & auditpol.exe /get /category:* /r 2>$null })
        if ($LASTEXITCODE -ne 0) { throw "auditpol exited with code $LASTEXITCODE" }
        $csv = @($lines | Where-Object { "$_".Trim() -ne '' })
        foreach ($r in @($csv | ConvertFrom-Csv)) {
            $setting = "$($r.'Inclusion Setting')".Trim()
            if ($onlyNone -and $setting -ne 'No Auditing') { continue }
            [pscustomobject]@{ subcategory = "$($r.Subcategory)".Trim(); setting = $setting; guid = "$($r.'Subcategory GUID')".Trim() }
        }
    }
    $all = @($fan.items)
    $sum = $fan.summary
    $sum['total'] = $all.Count
    $sum['truncated'] = ($all.Count -gt 500)
    @{ items = @($all | Select-Object -First 500); errors = $fan.errors; summary = $sum }
}
