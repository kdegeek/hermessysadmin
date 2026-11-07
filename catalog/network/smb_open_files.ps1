<# hermes-catalog
id: network.smb_open_files
title: Files open over SMB
category: Network
description: Files and folders that SMB clients have open on each server, with the user, client computer and lock count. Use it to find who has a file open before it can be replaced. PathContains filters to paths containing that text (case-insensitive). Defaults to every enabled server when no computers are given. Up to 200 rows per server.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, path, user, client, locks]
tags: [smb, open files, file locked, in use, who has file open, file server, net file]
source: In-box Get-SmbOpenFile
params:
  - {name: PathContains, type: string, description: 'Only paths containing this text, for example Finance\Budget.xlsx.'}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$PathContains)
Invoke-Op {
    if ($PathContains -and $PathContains -cnotmatch '\A[^\x00-\x1f*?"<>|]{1,200}\z') { throw 'InvalidArguments: PathContains must be 1-200 characters with no control characters or * ? " < > |' }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Server
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @("$PathContains") -Script {
        param($filter)
        $ErrorActionPreference = 'Stop'
        $files = @(Get-SmbOpenFile)
        if ($filter) { $files = @($files | Where-Object { "$($_.Path)".IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
        foreach ($f in @($files | Sort-Object Path | Select-Object -First 200)) {
            [pscustomobject]@{ path = "$($f.Path)"; user = "$($f.ClientUserName)"; client = "$($f.ClientComputerName)"; locks = [int]$f.Locks }
        }
    }
}
