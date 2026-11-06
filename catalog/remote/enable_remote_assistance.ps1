<# hermes-catalog
id: remote.enable_remote_assistance
title: Enable Remote Assistance
category: Remote access
description: Allows Remote Assistance and, when Unsolicited is true, lets an admin offer help with full control. Also enables the Remote Assistance firewall rules.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, before, after]
tags: [remote assistance, msra, remote access]
source: In-box registry (Remote Assistance and Terminal Services policy) and NetSecurity firewall rules
params:
  - {name: Unsolicited, type: boolean, default: true, description: Allow admins to offer Remote Assistance with full control.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$Unsolicited = $true, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    $want = [int]$Unsolicited
    $read = Invoke-HermesCatalogFanout -Computers $targets -Script {
        $a = $null; $u = $null
        try { $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -ErrorAction Stop).fAllowToGetHelp } catch { }
        try { $u = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction Stop).fAllowUnsolicited } catch { }
        [pscustomobject]@{ allow_to_get_help = $a; allow_unsolicited = $u }
    }
    if ($Preview) {
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ allow_to_get_help = $r['allow_to_get_help']; allow_unsolicited = $r['allow_unsolicited'] } }
        return @{ summary = "Enable Remote Assistance (unsolicited=$Unsolicited) on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): fAllowToGetHelp $($_['allow_to_get_help']) -> 1; fAllowUnsolicited $($_['allow_unsolicited']) -> $want" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($want) -Script {
        param($v)
        $ra = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
        Set-ItemProperty -Path $ra -Name fAllowToGetHelp -Value 1
        Set-ItemProperty -Path $pol -Name fAllowUnsolicited -Value $v -Type DWord
        Set-ItemProperty -Path $pol -Name fAllowUnsolicitedFullControl -Value $v -Type DWord
        Enable-NetFirewallRule -DisplayGroup 'Remote Assistance'
        [pscustomobject]@{ allow_to_get_help = (Get-ItemProperty $ra).fAllowToGetHelp; allow_unsolicited = (Get-ItemProperty $pol).fAllowUnsolicited }
    }
}
