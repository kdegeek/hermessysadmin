<# hermes-catalog
id: security.smb1
title: SMB1 status
category: Security posture
description: Whether the SMB1 server protocol is enabled and whether the SMB1 optional feature is installed.
module: inbox:SmbShare
target: endpoint
tier: R
columns: [host, smb1_server, feature]
tags: [smb1, smbv1, legacy protocol, eternalblue, cifs]
source: In-box SmbShare (Get-SmbServerConfiguration) and DISM optional features
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $srv = [bool](Get-SmbServerConfiguration).EnableSMB1Protocol
        $feature = 'unknown'
        try { $feature = "$((Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol).State)" } catch { $feature = 'unknown' }
        [pscustomobject]@{ smb1_server = $srv; feature = $feature }
    }
}
