<# hermes-catalog
id: security.uac_settings
title: User Account Control settings
category: Security posture
description: UAC on or off (EnableLUA), the elevation prompt for administrators and standard users, whether prompts use the secure desktop, admin approval mode for the built-in Administrator, and LocalAccountTokenFilterPolicy (1 gives local admin accounts a full token over the network, which helps pass-the-hash). Missing values show the Windows default.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, uac_enabled, admin_prompt, user_prompt, secure_desktop, builtin_admin_approval, local_account_token_filter]
tags: [uac, user account control, elevation, consent prompt, enablelua, localaccounttokenfilterpolicy, pass the hash]
source: In-box registry (Policies\System)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        function Get-V($Name, $Default) { if ($k -and $null -ne $k.$Name) { return [int]$k.$Name }; return $Default }
        $adminMap = @{ 0 = 'elevate without prompting'; 1 = 'credentials on secure desktop'; 2 = 'consent on secure desktop'; 3 = 'credentials'; 4 = 'consent'; 5 = 'consent for non-Windows binaries' }
        $userMap = @{ 0 = 'deny elevation'; 1 = 'credentials on secure desktop'; 3 = 'credentials' }
        $a = Get-V 'ConsentPromptBehaviorAdmin' 5
        $u = Get-V 'ConsentPromptBehaviorUser' 3
        $an = $adminMap[$a]; if (-not $an) { $an = "value $a" }
        $un = $userMap[$u]; if (-not $un) { $un = "value $u" }
        [pscustomobject]@{
            uac_enabled                = ((Get-V 'EnableLUA' 1) -ne 0)
            admin_prompt               = $an
            user_prompt                = $un
            secure_desktop             = ((Get-V 'PromptOnSecureDesktop' 1) -ne 0)
            builtin_admin_approval     = ((Get-V 'FilterAdministratorToken' 0) -eq 1)
            local_account_token_filter = ((Get-V 'LocalAccountTokenFilterPolicy' 0) -eq 1)
        }
    }
}
