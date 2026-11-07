<# hermes-catalog
id: ad.laps_coverage
title: LAPS coverage
category: AD hygiene
description: Which enabled non-DC computers have Windows LAPS or legacy LAPS managing a local admin password. Reads only the password expiration time attributes, never the passwords themselves. Computers with no LAPS are listed first.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, windows_laps, legacy_laps, expires]
tags: [laps, local admin password, windows laps, legacy laps, coverage, hygiene, bitlocker]
source: In-box ActiveDirectory (Get-ADComputer, expiration-time attributes only)
#>
param()
Invoke-Op {
    $toDate = {
        param($v)
        $n = 0L
        if ($null -ne $v -and [int64]::TryParse("$v", [ref]$n) -and $n -gt 0 -and $n -lt 2650467743999999999) { return [datetime]::FromFileTimeUtc($n) }
        return $null
    }
    $all = @(Get-ADComputer -LDAPFilter '(&(objectClass=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2))(!(userAccountControl:1.2.840.113556.1.4.803:=8192)))' -Properties 'msLAPS-PasswordExpirationTime', 'ms-Mcs-AdmPwdExpirationTime' |
        ForEach-Object {
            $w = & $toDate $_.'msLAPS-PasswordExpirationTime'
            $l = & $toDate $_.'ms-Mcs-AdmPwdExpirationTime'
            $exp = $null
            if ($w) { $exp = $w } elseif ($l) { $exp = $l }
            @{ name = $_.Name; windows_laps = [bool]$w; legacy_laps = [bool]$l; expires = (Iso $exp) }
        })
    $none = @($all | Where-Object { (-not $_.windows_laps) -and (-not $_.legacy_laps) })
    $covered = @($all | Where-Object { $_.windows_laps -or $_.legacy_laps })
    $rows = @(@($none | Sort-Object { $_.name }) + @($covered | Sort-Object { $_.name }))
    @{
        items   = @($rows | Select-Object -First 500)
        summary = @{
            total = $all.Count; windows_laps = @($all | Where-Object { $_.windows_laps }).Count
            legacy_laps = @($all | Where-Object { $_.legacy_laps }).Count; no_laps = $none.Count; truncated = ($rows.Count -gt 500)
        }
    }
}
