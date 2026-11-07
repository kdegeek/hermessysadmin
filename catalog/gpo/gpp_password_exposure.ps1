<# hermes-catalog
id: gpo.gpp_password_exposure
title: GPP password exposure
category: Group Policy
description: Finds Group Policy Preferences files in SYSVOL that contain a cpassword attribute, a reversibly encrypted password that any domain user can decrypt. Reports only how many matches each file has, never the value.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [gpo_guid, gpo_name, file, matches]
tags: [gpp, cpassword, group policy preferences, passwords, sysvol, ms14-025, exposure, security]
source: In-box local SYSVOL scan (Select-String match count only)
#>
param()
Invoke-Op {
    $pol = Join-Path $env:SystemRoot 'SYSVOL\domain\Policies'
    if (-not (Test-Path -LiteralPath $pol)) {
        $sv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -ErrorAction Stop).SysVol
        $pol = Join-Path $sv "$((Get-ADDomain).DNSRoot)\Policies"
    }
    $names = @{}
    foreach ($g in @(Get-GPO -All)) { $names["{$($g.Id.ToString().ToUpperInvariant())}"] = $g.DisplayName }
    $errs = @()
    $rows = @()
    $scanned = 0
    $xml = @(Get-ChildItem -LiteralPath $pol -Recurse -File -Filter *.xml -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\(Machine|User)\\Preferences\\' })
    foreach ($f in $xml) {
        $scanned++
        try {
            $count = 0
            Select-String -LiteralPath $f.FullName -Pattern 'cpassword="[^"]+' -AllMatches -ErrorAction Stop | ForEach-Object { $count += $_.Matches.Count }
            if ($count -gt 0) {
                $rel = $f.FullName.Substring($pol.Length).TrimStart('\')
                $guid = ($rel -split '\\')[0].ToUpperInvariant()
                $nm = $names[$guid]
                $rows += @{ gpo_guid = $guid; gpo_name = $nm; file = $rel; matches = $count }
            }
        } catch { $errs += @{ host = $env:COMPUTERNAME; message = "$($f.Name): $($_.Exception.Message)" } }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; files_scanned = $scanned; truncated = ($rows.Count -gt 500) } }
}
