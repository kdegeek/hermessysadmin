<# hermes-catalog
id: endpoint.scheduled_tasks
title: Non-Microsoft scheduled tasks
category: Endpoint health
description: Scheduled tasks outside the \Microsoft\ folder with their state, run-as account, last run, last result code and next run. failed is true when the last result is not success, running, queued or not-yet-run. Only the program path of each action is shown, never its arguments (they can hold credentials). At most 300 tasks per computer. Windows 8 / Server 2012 or later.
module: inbox:ScheduledTasks
target: endpoint
tier: R
columns: [host, path, name, state, run_as, last_run, last_result, failed, next_run, action]
tags: [scheduled task, task scheduler, schtasks, last run result, failed task, persistence]
source: In-box ScheduledTasks module (Get-ScheduledTask, Get-ScheduledTaskInfo)
params:
  - {name: FailedOnly, type: boolean, default: false, description: Only tasks whose last result was a failure.}
#>
param([string[]]$Computers = @(), [string]$Ou, [bool]$FailedOnly = $false)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($FailedOnly) -Script {
        param($failedOnly)
        # 0 success, 0x41300 ready, 0x41301 running, 0x41303 not yet run, 0x41325 queued
        $okCodes = @([int64]0, [int64]0x41300, [int64]0x41301, [int64]0x41303, [int64]0x41325)
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | Select-Object -First 300)
        foreach ($t in $tasks) {
            $info = $null
            try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { $info = $null }
            $code = $null; $hex = ''; $failed = $false; $last = $null; $next = $null
            if ($info) {
                if ($null -ne $info.LastTaskResult) {
                    $code = [int64]$info.LastTaskResult
                    if ($code -lt 0) { $code += 4294967296 }
                    $hex = '0x{0:X}' -f $code
                    $failed = ($okCodes -notcontains $code)
                }
                if ($info.LastRunTime -and $info.LastRunTime.Year -ge 2000) { $last = $info.LastRunTime.ToUniversalTime().ToString('o') }
                if ($info.NextRunTime -and $info.NextRunTime.Year -ge 2000) { $next = $info.NextRunTime.ToUniversalTime().ToString('o') }
            }
            if ($failedOnly -and -not $failed) { continue }
            $runAs = "$($t.Principal.UserId)"
            if (-not $runAs) { $runAs = "$($t.Principal.GroupId)" }
            $action = (@($t.Actions) | ForEach-Object { if ($_.Execute) { "$($_.Execute)" } else { 'COM handler' } }) -join '; '
            [pscustomobject]@{ path = "$($t.TaskPath)"; name = "$($t.TaskName)"; state = "$($t.State)"; run_as = $runAs
                               last_run = $last; last_result = $hex; failed = $failed; next_run = $next; action = $action }
        }
    }
}
