<# hermes-catalog
id: maint.gpupdate
title: Refresh computer policy
category: Maintenance
description: Runs gpupdate for computer policy on each computer so new Group Policy settings apply now.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, exit_code, output]
tags: [gpupdate, group policy, refresh, policy]
source: In-box gpupdate.exe
params:
  - {name: Force, type: boolean, default: true, description: Reapply all settings, not only changed ones.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$Force = $true, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        return @{ summary = "Run gpupdate /target:computer$(if ($Force) { ' /force' }) on $($targets.Count) computer(s)"
                  changes = @($targets | ForEach-Object { "${_}: gpupdate /target:computer$(if ($Force) { ' /force' })" })
                  current = @{ hosts = @($targets) } }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Force) -Script {
        param($force)
        $gp = @('/target:computer'); if ($force) { $gp += '/force' }
        $out = @(& { $ErrorActionPreference = 'Continue'; & gpupdate.exe @gp 2>&1 })
        $code = $LASTEXITCODE
        $text = (($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join ' ')
        if ($text.Length -gt 300) { $text = $text.Substring(0, 300) }
        [pscustomobject]@{ exit_code = $code; output = $text }
    }
}
