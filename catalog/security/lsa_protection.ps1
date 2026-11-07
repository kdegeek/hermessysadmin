<# hermes-catalog
id: security.lsa_protection
title: LSA protection, Credential Guard and WDigest
category: Security posture
description: Credential theft defences. lsa_ppl is the RunAsPPL setting (not set means off, except on Windows 11 22H2 and later where it can be on by default). vbs is virtualization-based security (off, configured or running). credential_guard and hvci say whether those services are running. wdigest_plaintext is true only when UseLogonCredential is 1, which keeps clear-text passwords in LSASS memory (on Windows 7 and Server 2008 R2 a missing value also means on; this entry reports only an explicit 1).
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, lsa_ppl, vbs, credential_guard, hvci, wdigest_plaintext]
tags: [lsa, lsass, runasppl, ppl, credential guard, vbs, hvci, memory integrity, wdigest, mimikatz, credential theft]
source: In-box registry (Lsa, WDigest) and CIM (root\Microsoft\Windows\DeviceGuard Win32_DeviceGuard)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $lsa = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        $ppl = 'not set'
        if ($null -ne $lsa.RunAsPPL) {
            switch ([int]$lsa.RunAsPPL) { 0 { $ppl = 'off' } 1 { $ppl = 'on (UEFI lock)' } 2 { $ppl = 'on (no UEFI lock)' } default { $ppl = "value $($lsa.RunAsPPL)" } }
        }
        $vbs = 'unknown'; $cg = $null; $hvci = $null
        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard
            switch ([int]$dg.VirtualizationBasedSecurityStatus) { 0 { $vbs = 'off' } 1 { $vbs = 'configured, not running' } 2 { $vbs = 'running' } }
            $running = @($dg.SecurityServicesRunning | ForEach-Object { [int]$_ })
            $cg = ($running -contains 1)
            $hvci = ($running -contains 2)
        } catch { $vbs = 'unsupported' }
        $wd = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -ErrorAction SilentlyContinue
        $wdig = $false
        if ($wd -and $null -ne $wd.UseLogonCredential -and [int]$wd.UseLogonCredential -eq 1) { $wdig = $true }
        [pscustomobject]@{ lsa_ppl = $ppl; vbs = $vbs; credential_guard = $cg; hvci = $hvci; wdigest_plaintext = $wdig }
    }
}
