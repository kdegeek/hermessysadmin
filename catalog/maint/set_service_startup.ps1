<# hermes-catalog
id: maint.set_service_startup
title: Set a service's startup type
category: Maintenance
description: Sets one Windows service's startup type to Automatic, Manual or Disabled. It does not start or stop the service; the change applies at the next start or reboot. Refuses services that management, logon, networking, security or the domain controller role depend on (for example WinRM, RpcSs, Netlogon, NTDS, DNS, the firewall and Defender) and anything that is not a Win32 service, such as drivers. Disabled always asks for approval.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, name, before, after]
tags: [service, startup type, disable service, automatic, manual, disabled, start mode]
source: In-box Set-Service and CIM Win32_Service
params:
  - {name: Name, type: string, required: true, description: Service name (not the display name) such as Spooler.}
  - {name: StartupType, type: string, required: true, enum: [Automatic, Manual, Disabled], description: The new startup type.}
escalate_when:
  StartupType: [Disabled]
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Name, [string]$StartupType, [switch]$Preview)
Invoke-Op {
    if ($Name -cnotmatch '\A[A-Za-z0-9_.-]{1,256}\z') { throw "InvalidArguments: Name must be 1-256 characters of letters, digits, '_', '.' or '-'" }
    if (@('Automatic', 'Manual', 'Disabled') -cnotcontains $StartupType) { throw 'InvalidArguments: StartupType must be Automatic, Manual or Disabled' }
    $critical = @('winrm', 'rpcss', 'rpceptmapper', 'dcomlaunch', 'lsm', 'samss', 'eventlog', 'eventsystem', 'plugplay', 'power',
                  'termservice', 'sessionenv', 'umrdpservice', 'netlogon', 'ntds', 'kdc', 'dns', 'dfsr', 'ismserv', 'w32time',
                  'mpssvc', 'bfe', 'windefend', 'wdnissvc', 'sense', 'lanmanworkstation', 'lanmanserver', 'nsi', 'dhcp', 'dnscache',
                  'nlasvc', 'netprofm', 'profsvc', 'schedule', 'winmgmt', 'cryptsvc', 'gpsvc', 'keyiso', 'trustedinstaller',
                  'brokerinfrastructure', 'systemeventsbroker', 'coremessagingregistrar')
    if ($critical -contains $Name.ToLowerInvariant()) {
        throw "PolicyBlocked: refusing to change the startup type of '$Name': management, logon, networking, security or the domain controller role depend on it."
    }
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    $mode = @{ Automatic = 'Auto'; Manual = 'Manual'; Disabled = 'Disabled' }[$StartupType]
    if ($Preview) {
        $read = Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name) -Script {
            param($n)
            $s = Get-CimInstance Win32_Service -Filter "Name = '$n'" -ErrorAction SilentlyContinue | Select-Object -First 1
            [pscustomobject]@{ name = $n; before = if ($s) { "$($s.StartMode)" } else { 'NotInstalled' }; state = if ($s) { "$($s.State)" } else { '' } }
        }
        $cur = @{}; foreach ($r in $read.items) { $cur[$r['host']] = @{ start_mode = $r['before']; state = $r['state'] } }
        return @{ summary = "Set service $Name to $StartupType on $($targets.Count) computer(s)"
                  changes = @($read.items | ForEach-Object {
                      if ($_['before'] -eq 'NotInstalled') { "$($_['host']): $Name is not installed; nothing changes" }
                      elseif ($_['before'] -eq $mode) { "$($_['host']): $Name is already $StartupType; nothing changes" }
                      else { "$($_['host']): $Name startup $($_['before']) -> $StartupType (currently $($_['state']))" } }) + @($read.errors | ForEach-Object { "$($_.host): unreachable ($($_.message))" })
                  current = $cur }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($Name, $StartupType) -Script {
        param($n, $type)
        $ErrorActionPreference = 'Stop'
        # Win32_Service only lists Win32 services, never kernel or file-system drivers.
        $s = Get-CimInstance Win32_Service -Filter "Name = '$n'" | Select-Object -First 1
        if (-not $s) { throw "NotFound: service '$n' is not installed (drivers are not supported)" }
        $before = "$($s.StartMode)"
        Set-Service -Name $n -StartupType $type
        $after = "$((Get-CimInstance Win32_Service -Filter "Name = '$n'" | Select-Object -First 1).StartMode)"
        [pscustomobject]@{ name = $n; before = $before; after = $after }
    }
}
