<# hermes-catalog
id: maint.restart_service
title: Restart a service
category: Maintenance
description: Restarts one Windows service by its service name. Refuses WinRM, RpcSs, LSM and TermService because restarting them would cut the management session.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, name, before, after]
tags: [service, restart, stop, start]
source: In-box Restart-Service
params:
  - {name: Name, type: string, required: true, description: Service name (not the display name), for example Spooler.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name, [switch]$Preview)
Invoke-Op {
    if ($Name -notmatch '^[A-Za-z0-9_.-]{1,256}$') { throw "Name must be 1-256 characters of letters, digits, '_', '.' or '-'" }
    if (@('winrm', 'rpcss', 'lsm', 'termservice') -contains $Name.ToLowerInvariant()) {
        throw "Refusing to restart '$Name': it would drop the management session or destabilise the machine."
    }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name) -Script {
        param($n)
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        [pscustomobject]@{ name = $n; before = if ($s) { "$($s.Status)" } else { 'NotInstalled' } }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Restart service $Name on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): restart $Name (currently $($_['before']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name) -Script {
        param($n)
        $ErrorActionPreference = 'Stop'
        $before = (Get-Service -Name $n).Status
        Restart-Service -Name $n
        [pscustomobject]@{ name = $n; before = "$before"; after = "$((Get-Service -Name $n).Status)" }
    }
}
