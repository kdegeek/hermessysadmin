<# hermes-catalog
id: security.defender_asr
title: Defender attack surface reduction rules
category: Security posture
description: The state of each Microsoft Defender attack surface reduction (ASR) rule on each computer, Block, Audit, Warn, Off or Not configured, from Get-MpPreference. Rules Windows does not know by name are listed by GUID. Fails on computers where Defender is not the active antivirus.
module: inbox:Defender
target: endpoint
tier: R
columns: [host, rule, action, rule_id]
tags: [defender, asr, attack surface reduction, exploit, office macros, lsass, ransomware, hardening]
source: In-box Defender (Get-MpPreference AttackSurfaceReductionRules_Ids and _Actions)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $names = [ordered]@{
            '56a863a9-875e-4185-98a7-b882c64b5ce5' = 'Block abuse of exploited vulnerable signed drivers'
            '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c' = 'Block Adobe Reader from creating child processes'
            'd4f940ab-401b-4efc-aadc-ad5f3c50688a' = 'Block all Office applications from creating child processes'
            '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2' = 'Block credential stealing from LSASS'
            'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550' = 'Block executable content from email client and webmail'
            '01443614-cd74-433a-b99e-2ecdc07bfc25' = 'Block executables unless they meet a prevalence, age or trusted list criterion'
            '5beb7efe-fd9a-4556-801d-275e5ffc04cc' = 'Block execution of potentially obfuscated scripts'
            'd3e037e1-3eb8-44c8-a917-57927947596d' = 'Block JavaScript or VBScript from launching downloaded executable content'
            '3b576869-a4ec-4529-8536-b80a7769e899' = 'Block Office applications from creating executable content'
            '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84' = 'Block Office applications from injecting code into other processes'
            '26190899-1602-49e8-8b27-eb1d0a1ce869' = 'Block Office communication application from creating child processes'
            'e6db77e5-3df2-4cf1-b95a-636979351e5b' = 'Block persistence through WMI event subscription'
            'd1e49aac-8f56-4280-b9ba-993a6d77406c' = 'Block process creations from PSExec and WMI commands'
            '33ddedf1-c6e0-47cb-833e-de6133960387' = 'Block rebooting machine in Safe Mode'
            'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4' = 'Block untrusted and unsigned processes that run from USB'
            'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb' = 'Block use of copied or impersonated system tools'
            'a8f5898e-1dc8-49a9-9878-85004b8a61e6' = 'Block webshell creation for servers'
            '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b' = 'Block Win32 API calls from Office macros'
            'c1db55ab-c21a-4637-bb3f-a12568109d35' = 'Use advanced protection against ransomware'
        }
        $actions = @{ 0 = 'Off'; 1 = 'Block'; 2 = 'Audit'; 6 = 'Warn' }
        $p = Get-MpPreference
        $ids = @($p.AttackSurfaceReductionRules_Ids)
        $acts = @($p.AttackSurfaceReductionRules_Actions)
        $set = @{}
        for ($i = 0; $i -lt $ids.Count; $i++) {
            if ($null -eq $ids[$i]) { continue }
            $a = 'unknown'
            if ($i -lt $acts.Count -and $null -ne $acts[$i]) {
                $raw = "$($acts[$i])"
                if ($raw -match '^\d+$') { $a = $actions[[int]$raw]; if (-not $a) { $a = "value $raw" } } else { $a = $raw }
            }
            $set["$($ids[$i])".ToLowerInvariant()] = $a
        }
        foreach ($id in $names.Keys) {
            $a = 'Not configured'
            if ($set.ContainsKey($id)) { $a = $set[$id] }
            [pscustomobject]@{ rule = $names[$id]; action = $a; rule_id = $id }
        }
        foreach ($id in $set.Keys) {
            if (-not $names.Contains($id)) { [pscustomobject]@{ rule = $id; action = $set[$id]; rule_id = $id } }
        }
    }
}
