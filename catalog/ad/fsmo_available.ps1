<# hermes-catalog
id: ad.fsmo_available
title: FSMO role availability
category: AD hygiene
description: The five FSMO role holders and whether each holder answers and has the AD DS (NTDS) service running. The service check runs on the holder itself, so no second hop is needed.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [role, holder, available]
tags: [fsmo, pdc emulator, rid master, schema master, infrastructure master, domain naming master, operations master]
source: In-box ActiveDirectory (Get-ADDomain, Get-ADForest) and the NTDS service on each holder
#>
param()
Invoke-Op {
    $dom = Get-ADDomain
    $for = Get-ADForest
    $roles = @(
        @{ role = 'Schema master'; holder = "$($for.SchemaMaster)" }
        @{ role = 'Domain naming master'; holder = "$($for.DomainNamingMaster)" }
        @{ role = 'PDC emulator'; holder = "$($dom.PDCEmulator)" }
        @{ role = 'RID master'; holder = "$($dom.RIDMaster)" }
        @{ role = 'Infrastructure master'; holder = "$($dom.InfrastructureMaster)" }
    )
    $holders = @($roles | ForEach-Object { $_.holder } | Where-Object { $_ } | Sort-Object -Unique)
    $fan = Invoke-HermesCatalogFanout -Computers $holders -Script {
        $ErrorActionPreference = 'Stop'
        $svc = Get-Service -Name NTDS
        [pscustomobject]@{ ntds = "$($svc.Status)" }
    }
    $rows = @(foreach ($r in $roles) {
        $hit = @($fan.items | Where-Object { $_.host -eq $r.holder })
        @{ role = $r.role; holder = $r.holder; available = ($hit.Count -gt 0 -and $hit[0].ntds -eq 'Running') }
    })
    @{ items = $rows; errors = $fan.errors; summary = @{ total = $rows.Count; truncated = $false; holders = $holders.Count; unavailable = @($rows | Where-Object { -not $_.available }).Count } }
}
