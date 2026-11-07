<# hermes-catalog
id: network.smb_sessions
title: SMB sessions on file servers
category: Network
description: SMB client sessions connected to each server, with the client computer, user, SMB dialect, number of open files and how long the session has existed and been idle. Defaults to every enabled server when no computers are given. Up to 200 sessions per server.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, client, user, dialect, open_files, connected_min, idle_min]
tags: [smb, sessions, file server, who is connected, open files, net session, cifs, dialect, smb1]
source: In-box Get-SmbSession
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Server
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        foreach ($s in @(Get-SmbSession | Sort-Object ClientUserName | Select-Object -First 200)) {
            [pscustomobject]@{
                client = "$($s.ClientComputerName)"; user = "$($s.ClientUserName)"; dialect = "$($s.Dialect)"; open_files = [int]$s.NumOpens
                connected_min = [int][math]::Floor([double]$s.SecondsExists / 60); idle_min = [int][math]::Floor([double]$s.SecondsIdle / 60)
            }
        }
    }
}
