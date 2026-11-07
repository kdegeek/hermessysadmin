<# hermes-catalog
id: maint.stop_process
title: Stop a process by name
category: Maintenance
description: Force-stops every process with the given name (for example a hung winword) on each computer, in every user session. Unsaved work in those processes is lost. Refuses Windows core processes (csrss, lsass, winlogon, services, smss, wininit, svchost and similar), the shell (explorer), console hosts, the remoting host that carries this session and Defender.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: H
preview: plan
columns: [host, name, found, stopped, failed, remaining]
tags: [process, kill, end task, taskkill, hung, not responding, stop process]
source: In-box Get-Process and Stop-Process
params:
  - {name: Name, type: string, required: true, description: Process name with or without .exe such as winword or notepad.exe.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name, [switch]$Preview)
Invoke-Op {
    if ($Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._-]{0,99}\z') { throw "InvalidArguments: Name must be 1-100 characters of letters, digits, spaces, '_', '.' or '-'" }
    $proc = $Name -replace '(?i)\.exe\z', ''
    $refused = @('system', 'idle', 'registry', 'secure system', 'memory compression', 'smss', 'csrss', 'wininit', 'winlogon', 'services',
                 'lsass', 'lsaiso', 'svchost', 'fontdrvhost', 'dwm', 'logonui', 'userinit', 'sihost', 'explorer', 'conhost',
                 'wsmprovhost', 'winrshost', 'wmiprvse', 'spoolsv', 'msmpeng', 'nissrv', 'mssense', 'securityhealthservice', 'taskhostw')
    if (-not $proc -or $refused -contains $proc.Trim().ToLowerInvariant()) {
        throw "PolicyBlocked: refusing to stop '$Name': it is a Windows core, shell, security or remoting process."
    }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($proc) -Script {
            param($n)
            $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
            [pscustomobject]@{ name = $n; found = $p.Count
                               sessions = (@($p | ForEach-Object { $_.SessionId } | Sort-Object -Unique) -join ',')
                               mb = [math]::Round((($p | Measure-Object -Property WorkingSet64 -Sum).Sum) / 1MB, 1) }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ found = $r['found']; sessions = $r['sessions'] } }
        return @{ summary = "Force-stop every '$proc' process on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object {
                      if ([int]$_['found'] -eq 0) { "$($_['host']): no $proc process running; nothing changes" }
                      else { "$($_['host']): stop $($_['found']) $proc process(es) in session(s) $($_['sessions']) using $($_['mb']) MB; unsaved work is lost" } }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($proc) -Script {
        param($n)
        $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID })
        $stopped = 0; $failed = 0
        foreach ($x in $p) {
            try { Stop-Process -Id $x.Id -Force -ErrorAction Stop; $stopped++ } catch { $failed++ }
        }
        Start-Sleep -Milliseconds 500
        [pscustomobject]@{ name = $n; found = $p.Count; stopped = $stopped; failed = $failed
                           remaining = @(Get-Process -Name $n -ErrorAction SilentlyContinue).Count }
    }
}
