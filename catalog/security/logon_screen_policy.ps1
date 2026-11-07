<# hermes-catalog
id: security.logon_screen_policy
title: Screen lock and logon screen policy
category: Security posture
description: Machine inactivity limit (InactivityTimeoutSecs; 0 or missing means no machine-wide lock), whether Ctrl+Alt+Del is required (empty when DisableCAD is not set; the default then depends on the Windows version and domain membership), whether the last signed-in user name is hidden, and whether a legal notice is shown (presence only, not its text). The per-user screen saver lock policy lives in each user's hive and is not read.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, inactivity_timeout_secs, ctrl_alt_del_required, hide_last_user, legal_notice]
tags: [screen lock, inactivity, idle lock, lock screen, ctrl alt del, logon banner, legal notice, last user name]
source: In-box registry (Policies\System)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        $idle = 0
        if ($k -and $null -ne $k.InactivityTimeoutSecs) { $idle = [int]$k.InactivityTimeoutSecs }
        $cad = $null
        if ($k -and $null -ne $k.DisableCAD) { $cad = ([int]$k.DisableCAD -eq 0) }
        [pscustomobject]@{
            inactivity_timeout_secs = $idle
            ctrl_alt_del_required   = $cad
            hide_last_user          = [bool]($k -and $null -ne $k.DontDisplayLastUserName -and [int]$k.DontDisplayLastUserName -eq 1)
            legal_notice            = [bool]($k -and "$($k.LegalNoticeCaption)$($k.LegalNoticeText)".Trim() -ne '')
        }
    }
}
