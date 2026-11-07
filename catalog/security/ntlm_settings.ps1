<# hermes-catalog
id: security.ntlm_settings
title: NTLM, LM hash and cached logon settings
category: Security posture
description: LmCompatibilityLevel (a missing value means 3, send NTLMv2 only; 5 also refuses LM and NTLMv1), whether LM hashes are stored (NoLMHash), the NTLM restriction and audit settings for outgoing and incoming traffic, the minimum NTLM session security and how many domain logons are cached for offline use (CachedLogonsCount, default 10).
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, lm_compat_level, lm_hash_stored, restrict_outgoing_ntlm, restrict_incoming_ntlm, audit_incoming_ntlm, min_client_sec, min_server_sec, cached_logons]
tags: [ntlm, ntlmv1, ntlmv2, lm hash, lmcompatibilitylevel, nolmhash, cached logons, cached credentials, relay]
source: In-box registry (Lsa, Lsa\MSV1_0, Winlogon)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $lsa = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        $msv = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0' -ErrorAction SilentlyContinue
        $wl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
        $lm = '3 (default)'
        if ($null -ne $lsa.LmCompatibilityLevel) { $lm = "$([int]$lsa.LmCompatibilityLevel)" }
        $noLm = $true
        if ($null -ne $lsa.NoLMHash -and [int]$lsa.NoLMHash -eq 0) { $noLm = $false }
        $out = 'allow all (default)'; $in = 'allow all (default)'; $aud = 'off (default)'; $cs = $null; $ss = $null
        if ($msv) {
            if ($null -ne $msv.RestrictSendingNTLMTraffic) { switch ([int]$msv.RestrictSendingNTLMTraffic) { 0 { $out = 'allow all' } 1 { $out = 'audit all' } 2 { $out = 'deny all' } default { $out = "value $($msv.RestrictSendingNTLMTraffic)" } } }
            if ($null -ne $msv.RestrictReceivingNTLMTraffic) { switch ([int]$msv.RestrictReceivingNTLMTraffic) { 0 { $in = 'allow all' } 1 { $in = 'deny domain accounts' } 2 { $in = 'deny all' } default { $in = "value $($msv.RestrictReceivingNTLMTraffic)" } } }
            if ($null -ne $msv.AuditReceivingNTLMTraffic) { switch ([int]$msv.AuditReceivingNTLMTraffic) { 0 { $aud = 'off' } 1 { $aud = 'domain accounts' } 2 { $aud = 'all accounts' } default { $aud = "value $($msv.AuditReceivingNTLMTraffic)" } } }
            foreach ($n in 'NtlmMinClientSec', 'NtlmMinServerSec') {
                $v = $msv.$n
                $txt = $null
                if ($null -ne $v) {
                    $u = [uint32]([int64]$v -band [int64]4294967295)
                    $parts = @()
                    if ($u -band 0x00080000) { $parts += 'NTLMv2 session security' }
                    if ($u -band 0x20000000) { $parts += '128-bit' }
                    if ($parts.Count -eq 0) { $parts += 'none' }
                    $txt = ('0x{0:X8} ({1})' -f $u, ($parts -join ', '))
                }
                if ($n -eq 'NtlmMinClientSec') { $cs = $txt } else { $ss = $txt }
            }
        }
        $cached = '10 (default)'
        if ($wl -and $null -ne $wl.CachedLogonsCount -and "$($wl.CachedLogonsCount)" -ne '') { $cached = "$($wl.CachedLogonsCount)" }
        [pscustomobject]@{
            lm_compat_level = $lm; lm_hash_stored = (-not $noLm); restrict_outgoing_ntlm = $out; restrict_incoming_ntlm = $in
            audit_incoming_ntlm = $aud; min_client_sec = $cs; min_server_sec = $ss; cached_logons = $cached
        }
    }
}
