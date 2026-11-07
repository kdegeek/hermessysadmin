<# hermes-catalog
id: network.hosts_file
title: Hosts file entries
category: Network
description: The active (non-comment) entries in each computer's hosts file, one row per name, with the file's last write time. Hosts entries override DNS, so unexpected ones explain wrong name resolution and can be a sign of tampering. Computers whose hosts file has no active entries return no rows. Up to 200 entries per computer.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, ip, name, line, modified]
tags: [hosts, hosts file, etc hosts, name resolution, override, dns, tampering]
source: In-box Get-Content of the hosts file (Tcpip DataBasePath)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $dir = Join-Path $env:SystemRoot 'System32\drivers\etc'
        try {
            $db = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name DataBasePath -ErrorAction Stop).DataBasePath
            if ($db) { $dir = [Environment]::ExpandEnvironmentVariables("$db") }
        } catch { }
        $path = Join-Path $dir 'hosts'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $modified = (Get-Item -LiteralPath $path).LastWriteTimeUtc.ToString('o')
        $n = 0
        $lineNo = 0
        foreach ($line in @(Get-Content -LiteralPath $path -TotalCount 5000)) {
            $lineNo++
            $text = ("$line" -replace '#.*$', '').Trim()
            if (-not $text) { continue }
            $parts = @($text -split '\s+')
            if ($parts.Count -lt 2) { continue }
            foreach ($name in @($parts | Select-Object -Skip 1)) {
                if ($n -ge 200) { return }
                $n++
                [pscustomobject]@{ ip = $parts[0]; name = $name; line = $lineNo; modified = $modified }
            }
        }
    }
}
