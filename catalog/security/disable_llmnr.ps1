<# hermes-catalog
id: security.disable_llmnr
title: Turn off LLMNR
category: Security posture
description: Turns off Link-Local Multicast Name Resolution by setting the local policy value EnableMulticast to 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient (the value the "Turn off multicast name resolution" Group Policy writes). Stops LLMNR poisoning; names that only resolved by LLMNR stop resolving, DNS is not affected. The DNS Client may only pick it up after the next policy refresh or restart, and a domain GPO that sets the same value wins at refresh. Undo by deleting the value. Does not touch NetBIOS or mDNS.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after, result]
tags: [llmnr, multicast, name resolution, responder, poisoning, hardening, dns client]
source: In-box registry (DNSClient policy EnableMulticast)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
        $before = $null
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if ($p -and $null -ne $p.EnableMulticast) { $before = [int]$p.EnableMulticast }
        $after = $before
        if ($before -eq 0) { $result = 'already off' }
        elseif (-not $apply) { $result = 'will set EnableMulticast to 0' }
        else {
            if (-not (Test-Path -LiteralPath $k)) { New-Item -Path $k -Force | Out-Null }
            Set-ItemProperty -LiteralPath $k -Name EnableMulticast -Value 0 -Type DWord
            $after = [int](Get-ItemProperty -LiteralPath $k).EnableMulticast
            $result = 'turned off'
        }
        [pscustomobject]@{ before = $(if ($null -eq $before) { 'not set (on)' } else { "$before" }); after = $(if ($null -eq $after) { 'not set (on)' } else { "$after" }); result = $result }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Turn off LLMNR on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): EnableMulticast $($_['before']) -> 0 ($($_['result']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
