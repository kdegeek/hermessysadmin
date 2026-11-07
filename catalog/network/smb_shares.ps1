<# hermes-catalog
id: network.smb_shares
title: SMB shares
category: Network
description: Non-special SMB shares with their local path, plus the number of SMB sessions currently connected to the computer.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, share, path, sessions]
tags: [smb, shares, file shares, sessions, cifs]
source: In-box Get-SmbShare and Get-SmbSession
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $sessions = @(Get-SmbSession -ErrorAction SilentlyContinue).Count
        foreach ($s in @(Get-SmbShare | Where-Object { -not $_.Special } | Select-Object -First 200)) {
            [pscustomobject]@{ share = "$($s.Name)"; path = "$($s.Path)"; sessions = $sessions }
        }
    }
}
