<# hermes-catalog
id: events.rdp_logons
title: Remote Desktop logons (4624 type 10)
category: Event logs
description: Successful Remote Desktop sign-ins (Security 4624, logon type 10) with the user and source IP.
module: inbox:Microsoft.PowerShell.Diagnostics
target: endpoint
tier: R
columns: [host, user, source_ip, time]
tags: [rdp, remote desktop, logon, 4624, type 10, security log, sign-in]
source: In-box Get-WinEvent -FilterXPath
params:
  - {name: Hours, type: integer, default: 24, minimum: 1, maximum: 720, description: How many hours back to look.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Hours = 24)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Hours) -Script {
        param($h)
        $ErrorActionPreference = 'Stop'
        $ms = [int64]$h * 3600000
        $xpath = "*[System[(EventID=4624) and TimeCreated[timediff(@SystemTime) <= $ms]]] and *[EventData[Data[@Name='LogonType']='10']]"
        try {
            $events = @(Get-WinEvent -LogName Security -FilterXPath $xpath -MaxEvents 200)
        } catch {
            if ("$($_.FullyQualifiedErrorId)" -like 'NoMatchingEventsFound*') { return }
            throw
        }
        foreach ($e in $events) {
            $d = @{}
            foreach ($n in ([xml]$e.ToXml()).Event.EventData.Data) { $d["$($n.Name)"] = "$($n.'#text')" }
            [pscustomobject]@{ user = $d['TargetUserName']; source_ip = $d['IpAddress']; time = $e.TimeCreated.ToUniversalTime().ToString('o') }
        }
    }
}
