<# hermes-catalog
id: gpo.netlogon_files
title: NETLOGON files
category: Group Policy
description: Files in this domain controller's NETLOGON share (logon scripts and other files) with owner, size and modified time. File contents are never read.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [path, owner, size, modified]
tags: [netlogon, logon script, scripts, sysvol, files, owner, legacy]
source: In-box local SYSVOL file listing (Get-ChildItem, Get-Acl)
#>
param()
Invoke-Op {
    $dcName = Get-HermesDc
    $root = Get-HermesSysvolPath -Child scripts
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 501)
    $errs = @()
    $rows = @(foreach ($f in @($files | Select-Object -First 500)) {
        $owner = $null
        try { $owner = "$((Get-Acl -LiteralPath $f.FullName -ErrorAction Stop).Owner)" } catch { $errs += @{ host = $dcName; message = "$($f.Name): $($_.Exception.Message)" } }
        @{ path = $f.FullName.Substring($root.Length).TrimStart('\'); owner = $owner; size = [int64]$f.Length; modified = (Iso $f.LastWriteTime) }
    })
    @{ items = $rows; errors = $errs; summary = @{ total = $rows.Count; truncated = ($files.Count -gt 500); root = $root } }
}
