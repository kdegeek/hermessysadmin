<# hermes-catalog
id: security.defender_quick_scan
title: Start a Defender quick scan
category: Security posture
description: Starts a Microsoft Defender quick scan on each computer and returns at once; the scan runs in the background (MpCmdRun -Scan -ScanType 1, started through WMI so it outlives the remote session) and shows in security.defender_status as last_quick_scan when it finishes. Threats found are handled by the computer's normal Defender actions (usually quarantine). Skips computers where Defender antivirus is not active. Uses CPU and disk for a few minutes.
module: inbox:Defender
target: endpoint
tier: W
preview: plan
columns: [host, result, last_quick_scan, process_id]
tags: [defender, scan, quick scan, antivirus, malware, mpcmdrun]
source: In-box Defender (Get-MpComputerStatus), MpCmdRun.exe and CIM (Win32_Process Create)
#>
param([string[]]$Computers = @(), [string]$Ou, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $work = {
        param($apply)
        $ErrorActionPreference = 'Stop'
        $s = $null
        try { $s = Get-MpComputerStatus } catch { $s = $null }
        $last = $null
        if ($s -and $s.QuickScanEndTime) { $last = ([datetime]$s.QuickScanEndTime).ToUniversalTime().ToString('o') }
        $exe = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
        $reason = $null
        if (-not $s -or -not $s.AntivirusEnabled) { $reason = 'Defender antivirus is not active' }
        elseif (-not (Test-Path -LiteralPath $exe)) { $reason = 'MpCmdRun.exe not found' }
        if ($reason) { return [pscustomobject]@{ result = "skipped: $reason"; last_quick_scan = $last; process_id = $null } }
        if (-not $apply) { return [pscustomobject]@{ result = 'will start a quick scan'; last_quick_scan = $last; process_id = $null } }
        # Fixed command line, nothing from the caller. Win32_Process.Create keeps the scan alive after WinRM closes.
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$exe`" -Scan -ScanType 1" }
        if ([int]$r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
        [pscustomobject]@{ result = 'quick scan started'; last_quick_scan = $last; process_id = [int]$r.ProcessId }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ last_quick_scan = $r['last_quick_scan'] } }
        return @{ summary = "Start a Defender quick scan on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['result']) (last quick scan $($_['last_quick_scan']))" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
