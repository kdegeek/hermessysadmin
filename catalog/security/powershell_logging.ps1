<# hermes-catalog
id: security.powershell_logging
title: PowerShell v2 and logging policy
category: Security posture
description: Whether the PowerShell 2.0 engine (which bypasses script block logging and AMSI) is still installed, whether script block, module and transcription logging are turned on by policy, the transcript folder if set, and the machine execution policy. ps_v2 is 'not present' on builds that removed it and 'unknown' when the feature query fails.
module: inbox:Dism
target: endpoint
tier: R
columns: [host, ps_v2, script_block_logging, module_logging, transcription, transcript_dir, execution_policy]
tags: [powershell, powershell v2, downgrade, script block logging, module logging, transcription, amsi, execution policy, logging]
source: In-box Dism (Get-WindowsOptionalFeature), registry (Policies\Microsoft\Windows\PowerShell) and Get-ExecutionPolicy
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $v2 = 'unknown'
        try {
            $f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2
            if ($f) { $v2 = "$($f.State)" } else { $v2 = 'not present' }
        } catch { $v2 = 'unknown' }
        $base = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
        function Get-On([string]$Sub, [string]$Name) {
            $k = Get-ItemProperty -LiteralPath "$base\$Sub" -ErrorAction SilentlyContinue
            return ($k -and $null -ne $k.$Name -and [int]$k.$Name -eq 1)
        }
        $tr = Get-ItemProperty -LiteralPath "$base\Transcription" -ErrorAction SilentlyContinue
        $dir = $null
        if ($tr -and $tr.OutputDirectory) { $dir = "$($tr.OutputDirectory)" }
        $ep = 'unknown'
        try {
            $mp = Get-ExecutionPolicy -Scope MachinePolicy
            if ("$mp" -ne 'Undefined') { $ep = "$mp (policy)" } else { $ep = "$(Get-ExecutionPolicy -Scope LocalMachine)" }
        } catch { $ep = 'unknown' }
        [pscustomobject]@{
            ps_v2                = $v2
            script_block_logging = (Get-On 'ScriptBlockLogging' 'EnableScriptBlockLogging')
            module_logging       = (Get-On 'ModuleLogging' 'EnableModuleLogging')
            transcription        = (Get-On 'Transcription' 'EnableTranscripting')
            transcript_dir       = $dir
            execution_policy     = $ep
        }
    }
}
