<# hermes-catalog
id: endpoint.pending_reboot
title: Pending reboot
category: Endpoint health
description: Whether a restart is pending and why (component servicing, Windows Update, file renames, computer rename).
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, pending, reasons]
tags: [reboot, restart, pending, updates]
source: In-box registry (CBS, WindowsUpdate, Session Manager, ComputerName)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Component servicing' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
        $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($sm -and $sm.PendingFileRenameOperations) { $reasons += 'Pending file rename' }
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
        $wanted = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
        if ($active -and $wanted -and $active -ne $wanted) { $reasons += 'Computer rename' }
        [pscustomobject]@{ pending = ($reasons.Count -gt 0); reasons = @($reasons) }
    }
}
