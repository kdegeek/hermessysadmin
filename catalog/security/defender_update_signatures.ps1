<# hermes-catalog
id: security.defender_update_signatures
title: Update Defender signatures
category: Security posture
description: Starts a Microsoft Defender security intelligence (signature) update on each computer from its configured update sources and returns at once (MpCmdRun -SignatureUpdate, started through WMI so it outlives the remote session). Check the new version a few minutes later with security.defender_status. Skips computers where Defender antivirus is not active.
module: inbox:Defender
target: endpoint
tier: W
preview: plan
columns: [host, result, sig_version, sig_age_days, process_id]
tags: [defender, signatures, definitions, security intelligence, update, antivirus, mpcmdrun]
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
        $ver = $null; $age = $null
        if ($s) { $ver = "$($s.AntivirusSignatureVersion)"; $age = $s.AntivirusSignatureAge }
        $exe = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
        $reason = $null
        if (-not $s -or -not $s.AntivirusEnabled) { $reason = 'Defender antivirus is not active' }
        elseif (-not (Test-Path -LiteralPath $exe)) { $reason = 'MpCmdRun.exe not found' }
        if ($reason) { return [pscustomobject]@{ result = "skipped: $reason"; sig_version = $ver; sig_age_days = $age; process_id = $null } }
        if (-not $apply) { return [pscustomobject]@{ result = 'will start a signature update'; sig_version = $ver; sig_age_days = $age; process_id = $null } }
        # Fixed command line, nothing from the caller.
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "`"$exe`" -SignatureUpdate" }
        if ([int]$r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
        [pscustomobject]@{ result = 'signature update started'; sig_version = $ver; sig_age_days = $age; process_id = [int]$r.ProcessId }
    }
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($false) -Script $work
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ sig_version = $r['sig_version']; sig_age_days = $r['sig_age_days'] } }
        return @{ summary = "Start a Defender signature update on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['result']) (now $($_['sig_version']), $($_['sig_age_days']) day(s) old)" }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($true) -Script $work
}
