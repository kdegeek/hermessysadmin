<# hermes-catalog
id: patch.trigger_scan
title: Start a Windows Update scan
category: Patching
description: Asks each computer to start a Windows Update scan now (UsoClient StartScan). It does not install anything.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, started, exit_code]
tags: [windows update, scan, check for updates, usoclient, patching]
source: In-box UsoClient.exe
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        return @{ summary = "Start a Windows Update scan on $($targets.Count) computer(s)"
                 changes = @($targets | ForEach-Object { "${_}: UsoClient StartScan" })
                 current = @{ hosts = @($targets) } }
    }
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $exe = Join-Path $env:windir 'System32\UsoClient.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw 'UsoClient.exe is not present on this computer.' }
        $code = & { $ErrorActionPreference = 'Continue'; & $exe StartScan 2>$null | Out-Null; [uint32]$LASTEXITCODE }
        [pscustomobject]@{ started = ($code -eq 0); exit_code = $code }
    }
}
