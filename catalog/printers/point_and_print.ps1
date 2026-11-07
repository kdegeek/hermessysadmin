<# hermes-catalog
id: printers.point_and_print
title: Point and Print (PrintNightmare) settings
category: Printers
description: The Point and Print policy values that decide whether non-admins can install printer drivers (the PrintNightmare exposure), plus the Print Spooler state. restrict_to_admins is empty when not configured, which since August 2021 means restricted. risky is true when driver installation was opened to non-admins and the install or update warning is suppressed. spooler_on_dc flags a running spooler on a domain controller, which Microsoft recommends disabling.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, restrict_to_admins, no_warning_on_install, update_prompt, trusted_servers, server_list, package_only, spooler, spooler_on_dc, risky]
tags: [printnightmare, point and print, printer driver, spooler, cve-2021-34527, restrictdriverinstallationtoadministrators, hardening, security]
source: In-box registry (HKLM Policies Printers\PointAndPrint, PackagePointAndPrint), Get-Service Spooler and Win32_ComputerSystem
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $pp = $null
        try { $pp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint' -ErrorAction Stop } catch { $pp = $null }
        $pkg = $null
        try { $pkg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PackagePointAndPrint' -ErrorAction Stop } catch { $pkg = $null }
        $val = { param($o, $n) if ($o -and $null -ne $o.$n) { [int]$o.$n } else { $null } }
        $restrict = & $val $pp 'RestrictDriverInstallationToAdministrators'
        $noWarn = & $val $pp 'NoWarningNoElevationOnInstall'
        $update = & $val $pp 'UpdatePromptSettings'
        $trusted = & $val $pp 'TrustedServers'
        $list = $null
        if ($pp -and $pp.ServerList) { $list = "$($pp.ServerList)" }
        $pkgOnly = & $val $pkg 'PackagePointAndPrintOnly'
        $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
        $state = $(if ($svc) { "$($svc.Status) ($($svc.StartType))" } else { 'NotInstalled' })
        $isDc = ([int](Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4)
        [pscustomobject]@{
            restrict_to_admins = $restrict; no_warning_on_install = $noWarn; update_prompt = $update; trusted_servers = $trusted; server_list = $list
            package_only = $pkgOnly; spooler = $state; spooler_on_dc = ($isDc -and $svc -and "$($svc.Status)" -eq 'Running')
            risky = ($restrict -eq 0 -and ($noWarn -eq 1 -or $update -ge 1))
        }
    }
}
