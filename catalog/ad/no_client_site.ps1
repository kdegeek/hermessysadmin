<# hermes-catalog
id: ad.no_client_site
title: Clients outside every AD subnet
category: AD hygiene
description: Computers whose IP address matched no AD subnet when they contacted a domain controller (NO_CLIENT_SITE lines in each DC's Netlogon log, the current and the previous file), grouped by client name and address with a count, the time of the latest line and a /24 hint for the missing subnet. Such clients may authenticate against a distant DC. Netlogon logs carry no year, so last_seen is month/day and time as written. Only the last MaxLines lines of each file are read.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [client, ip, host, count, last_seen, subnet_hint]
tags: [no_client_site, netlogon log, missing subnet, sites and services, client site, dc locator, subnets]
source: In-box Get-Content of %SystemRoot%\debug\netlogon.log and netlogon.bak, read on each DC through the fan-out
params:
  - {name: MaxLines, type: integer, default: 20000, minimum: 100, maximum: 200000, description: How many lines to read from the end of each Netlogon log file on each DC.}
#>
param([int]$MaxLines = 20000)
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName } | Where-Object { $_ })
    $fan = Invoke-HermesCatalogFanout -Computers $dcs -ArgumentList @($MaxLines) -Script {
        param($max)
        $seen = @{}
        foreach ($f in @("$env:SystemRoot\debug\netlogon.bak", "$env:SystemRoot\debug\netlogon.log")) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            foreach ($line in @(Get-Content -LiteralPath $f -Tail $max -ErrorAction SilentlyContinue)) {
                if ("$line" -cmatch '^(\d\d/\d\d \d\d:\d\d:\d\d) .*NO_CLIENT_SITE:\s+(\S+)\s+(\S+)') {
                    $key = "$($Matches[2])|$($Matches[3])"
                    if ($seen.ContainsKey($key)) { $seen[$key].count++; $seen[$key].last = $Matches[1] }
                    else { $seen[$key] = @{ client = $Matches[2]; ip = $Matches[3]; count = 1; last = $Matches[1] } }
                }
            }
        }
        foreach ($v in $seen.Values) {
            $hint = ''
            if ($v.ip -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { $hint = "$($Matches[1]).0/24" }
            [pscustomobject]@{ client = $v.client; ip = $v.ip; count = $v.count; last_seen = $v.last; subnet_hint = $hint }
        }
    }
    $rows = @($fan.items | Sort-Object { -[int]$_['count'] })
    @{ items = @($rows | Select-Object -First 500); errors = $fan.errors
       summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); dcs = $dcs.Count; dcs_ok = $fan.summary.ok; dcs_failed = $fan.summary.failed
                    distinct_ips = @($rows | ForEach-Object { $_['ip'] } | Sort-Object -Unique).Count; max_lines = $MaxLines } }
}
