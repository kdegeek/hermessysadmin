<# hermes-catalog
id: patch.wu_install
title: Install security and critical updates
category: Patching
description: Starts a one-shot SYSTEM scheduled task on each computer that downloads and installs security and/or critical updates with the Windows Update Agent. The preview lists the updates found. Progress is logged to C:\Windows\Temp\HermesSysadmin-WUInstall.log on each computer.
module: inbox:ScheduledTasks
target: endpoint
tier: H
preview: plan
columns: [host, task_registered, updates_queued]
tags: [install updates, patch, windows update, security updates, critical updates, patching, scheduled task]
source: In-box Windows Update Agent COM API via a SYSTEM scheduled task
params:
  - {name: Category, type: string, enum: [security, critical, both], default: both, description: Which update categories to install.}
  - {name: AutoReboot, type: boolean, default: false, description: Restart the computer five minutes after installing if an update requires it.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Category = 'both', [bool]$AutoReboot = $false, [switch]$Preview)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    if ($Category -notin @('security', 'critical', 'both')) { throw "Category must be security, critical or both." }

    # Every piece below is a constant chosen by if; no caller text is ever placed in the task command.
    $guidSecurity = '0FA1201D-4330-4FA8-8AE9-B877473B6441'
    $guidCritical = 'E6CF1350-C01B-414D-A61F-263D14D133B4'
    $guidList = if ($Category -eq 'security') { $guidSecurity } elseif ($Category -eq 'critical') { $guidCritical } else { "$guidSecurity,$guidCritical" }

    $bodyTemplate = @'
$ErrorActionPreference = 'Stop'
$log = 'C:\Windows\Temp\HermesSysadmin-WUInstall.log'
function Write-Log($m) { Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date).ToString('o'), $m) }
try {
    Write-Log 'start'
    $session = New-Object -ComObject Microsoft.Update.Session
    $found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
    $want = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
        $ids = @($u.Categories | ForEach-Object { $_.CategoryID })
        if (@($ids | Where-Object { @(__GUIDS__) -contains $_ }).Count -gt 0) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$want.Add($u)
            Write-Log ('queued ' + $u.Title)
        }
    }
    Write-Log ('matched ' + $want.Count)
    if ($want.Count -gt 0) {
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $want
        [void]$dl.Download()
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $want
        $res = $inst.Install()
        Write-Log ('result ' + $res.ResultCode + ' reboot ' + $res.RebootRequired)
        __REBOOT__
    }
    Write-Log 'done'
} catch {
    Write-Log ('error ' + $_.Exception.Message)
}
'@
    $rebootYes = 'if ($res.RebootRequired) { Write-Log ''restart in 300 seconds''; & shutdown.exe /r /t 300 }'
    $rebootNo = 'Write-Log ''no automatic restart requested'''
    $rebootLine = if ($AutoReboot) { $rebootYes } else { $rebootNo }
    $quoted = ($guidList -split ',' | ForEach-Object { "'$_'" }) -join ','
    $body = $bodyTemplate.Replace('__GUIDS__', $quoted).Replace('__REBOOT__', $rebootLine)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))

    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($guidList) -Script {
            param($guids)
            $ErrorActionPreference = 'Stop'
            $want = @($guids -split ',')
            try {
                $session = New-Object -ComObject Microsoft.Update.Session
                $found = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
            } catch {
                if ("$($_.Exception.Message)" -match '0x80070005|Access is denied' -or $_.Exception.HResult -eq -2147024891) {
                    throw 'Windows Update search was denied over remoting (0x80070005); the updates cannot be listed here.'
                }
                throw
            }
            $rows = @(foreach ($u in $found.Updates) {
                $ids = @($u.Categories | ForEach-Object { $_.CategoryID })
                if (@($ids | Where-Object { $want -contains $_ }).Count -gt 0) {
                    $kbs = @($u.KBArticleIDs | ForEach-Object { "KB$_" })
                    $t = "$($u.Title)"
                    [pscustomobject]@{ kb = ($kbs -join ', '); title = $t.Substring(0, [math]::Min(300, $t.Length)) }
                }
            })
            $rows | Select-Object -First 200
        }
        $cur = @{}
        foreach ($r in $read.items) { $h = $r['host']; $cur[$h] = 1 + $(if ($cur.ContainsKey($h)) { $cur[$h] } else { 0 }) }
        return @{ summary = "Install $Category updates on $($targets.Count) computer(s); AutoReboot=$AutoReboot"
                  changes = @($read.items | ForEach-Object { "$($_['host']): $($_['kb']) $($_['title'])" }) + @($read.errors | ForEach-Object { "$($_.host): could not list updates ($($_.message))" })
                  current = $cur }
    }

    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($b64, $guidList) -Script {
        param($encoded, $guids)
        $ErrorActionPreference = 'Stop'
        $name = 'HermesSysadmin-WUInstall'
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -StartWhenAvailable
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Description 'One-shot update install started by hermes-sysadmin' | Out-Null
        Start-ScheduledTask -TaskName $name
        # Best-effort count of what the task will pick up; unknown (null) when the search is denied or slow.
        $queued = $null
        try {
            $want = @($guids -split ',')
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $job = $searcher.BeginSearch('IsInstalled=0 and IsHidden=0', $null, $null)
            [void]$job.AsyncWaitHandle.WaitOne(20000)
            if ($job.IsCompleted) {
                $res = $searcher.EndSearch($job)
                $n = 0
                foreach ($u in $res.Updates) {
                    $ids = @($u.Categories | ForEach-Object { $_.CategoryID })
                    if (@($ids | Where-Object { $want -contains $_ }).Count -gt 0) { $n++ }
                }
                $queued = $n
            }
        } catch { $queued = $null }
        [pscustomobject]@{ task_registered = $true; updates_queued = $queued }
    }
}
