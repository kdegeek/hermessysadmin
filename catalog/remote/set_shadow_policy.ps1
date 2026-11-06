<# hermes-catalog
id: remote.set_shadow_policy
title: Set Remote Desktop shadow policy
category: Remote access
description: Sets the Remote Desktop Services shadow policy. 0 means shadowing is not allowed. 1 is full control with consent. 2 is full control without consent. 3 is view only with consent. 4 is view only without consent.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [rdp, shadow, remote desktop, policy]
source: In-box registry (Terminal Services policy Shadow)
params:
  - {name: Level, type: integer, default: 2, minimum: 0, maximum: 4, description: Shadow level 0 none 1 full with consent 2 full without consent 3 view with consent 4 view without consent.}
#>
param([string[]]$Computers = @(), [string]$Ou, [int]$Level = 2, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        $v = $null
        try { $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction Stop).Shadow } catch { }
        [pscustomobject]@{ before = $v }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = $r['before'] }
        return @{ summary = "Set the shadow policy to $Level on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): Shadow $($_['before']) -> $Level" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Level) -Script {
        param($v)
        $ErrorActionPreference = 'Stop'
        $k = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        $before = $null
        try { $before = (Get-ItemProperty $k -ErrorAction Stop).Shadow } catch { }
        Set-ItemProperty -Path $k -Name Shadow -Value $v -Type DWord
        [pscustomobject]@{ before = $before; after = (Get-ItemProperty $k).Shadow }
    }
}
