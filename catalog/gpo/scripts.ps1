<# hermes-catalog
id: gpo.scripts
title: GPO startup, shutdown, logon and logoff scripts
category: Group Policy
description: Scripts that GPOs run at computer startup or shutdown and user logon or logoff, read from each GPO's scripts.ini and psscripts.ini in SYSVOL. Shows the script path, whether it is a batch or PowerShell script, where it lives and, for scripts stored inside the GPO, whether the file exists. Script parameters are never shown (they sometimes carry credentials); has_parameters says whether any are set. Script contents are not read.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [gpo, side, phase, kind, script, has_parameters, location, exists, side_enabled]
tags: [gpo, group policy, startup script, shutdown script, logon script, logoff script, scripts.ini, psscripts.ini, sysvol]
source: In-box GroupPolicy (Get-GPO) and read-only SYSVOL file reads (Get-Content of scripts.ini and psscripts.ini)
#>
param()
Invoke-Op {
    $dcName = Get-HermesDc
    $pol = Get-HermesSysvolPath -Child Policies
    $errs = @()
    $rows = @()
    $gpos = @(Get-GPO -All | Sort-Object DisplayName)
    foreach ($g in $gpos) {
        $dir = Join-Path $pol ('{' + $g.Id.ToString().ToUpperInvariant() + '}')
        $status = "$($g.GpoStatus)"
        foreach ($side in @('Machine', 'User')) {
            $label = $(if ($side -eq 'Machine') { 'Computer' } else { 'User' })
            $enabled = -not ($status -eq 'AllSettingsDisabled' -or ($side -eq 'Machine' -and $status -eq 'ComputerSettingsDisabled') -or ($side -eq 'User' -and $status -eq 'UserSettingsDisabled'))
            foreach ($file in @('scripts.ini', 'psscripts.ini')) {
                $ini = Join-Path $dir "$side\Scripts\$file"
                try {
                    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { continue }
                    $section = $null
                    $entries = @{}
                    $order = @()
                    foreach ($line in @(Get-Content -LiteralPath $ini -ErrorAction Stop)) {
                        $t = "$line".Trim()
                        if ($t -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
                        if (-not $section -or $t -notmatch '^(\d+)(CmdLine|Parameters)=(.*)$') { continue }
                        $key = "$section|$($Matches[1])"
                        $field = $Matches[2]
                        $value = $Matches[3]
                        if (-not $entries.ContainsKey($key)) { $entries[$key] = @{ section = $section; cmd = ''; params = '' }; $order += $key }
                        if ($field -eq 'CmdLine') { $entries[$key]['cmd'] = $value } else { $entries[$key]['params'] = $value }
                    }
                    foreach ($key in $order) {
                        $e = $entries[$key]
                        $cmd = "$($e['cmd'])".Trim()
                        if (-not $cmd) { continue }
                        $location = 'inside the GPO'
                        $exists = $null
                        if ($cmd -match '^\\\\') { $location = 'UNC path' }
                        elseif ($cmd -match '^[A-Za-z]:') { $location = 'local path on the client' }
                        elseif ($cmd -notmatch '\.\.' -and $cmd -notmatch '[*?:]') {
                            $exists = Test-Path -LiteralPath (Join-Path $dir "$side\Scripts\$($e['section'])\$cmd") -PathType Leaf
                        }
                        $rows += @{
                            gpo = $g.DisplayName
                            side = $label
                            phase = "$($e['section'])"
                            kind = $(if ($file -eq 'psscripts.ini') { 'PowerShell' } else { 'batch or executable' })
                            script = $(if ($cmd.Length -gt 300) { $cmd.Substring(0, 300) } else { $cmd })
                            has_parameters = ("$($e['params'])".Trim() -ne '')
                            location = $location
                            exists = $exists
                            side_enabled = $enabled
                        }
                    }
                } catch { $errs += @{ host = $dcName; message = "$($g.DisplayName) $side\Scripts\$($file): $($_.Exception.Message)" } }
            }
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; gpos = $gpos.Count; gpos_with_scripts = @($rows | ForEach-Object { $_.gpo } | Sort-Object -Unique).Count; missing_files = @($rows | Where-Object { $_.exists -eq $false }).Count; truncated = ($rows.Count -gt 500) } }
}
