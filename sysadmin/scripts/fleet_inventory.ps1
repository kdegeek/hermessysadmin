param(
    [string]$Ou,
    [ValidateSet('workstation','server','any')][string]$Kind = 'workstation',
    [bool]$Refresh = $false,
    [string]$ServerSearchBase
)
Invoke-Op {
    $props = 'DNSHostName','OperatingSystem','OperatingSystemVersion','LastLogonDate','Enabled','DistinguishedName'
    $filter = switch ($Kind) {
        'workstation' { "Enabled -eq 'True' -and OperatingSystem -notlike '*Server*'" }
        'server'      { "Enabled -eq 'True' -and OperatingSystem -like '*Server*'" }
        default       { "Enabled -eq 'True'" }
    }
    $adArgs = @{ Filter = $filter; Properties = $props }
    if ($Ou) { $adArgs['SearchBase'] = $Ou }
    elseif ($Kind -eq 'server' -and $ServerSearchBase) { $adArgs['SearchBase'] = $ServerSearchBase }
    $ad = @(Get-ADComputer @adArgs | Select-Object -First 500)
    $names = @($ad | ForEach-Object { if ($_.DNSHostName) { $_.DNSHostName } else { $_.Name } })
    $probe = Invoke-HermesCatalogFanout -Computers $names -Script {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
        $pfr = $null
        try { $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations } catch { }
        if ($pfr) { $reasons += 'PendingFileRename' }
        $hf = $null
        try { $hf = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1 } catch { }
        $mp = $null
        try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
        $bl = $null
        try { $bl = (Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='C:'" -ErrorAction Stop).ProtectionStatus } catch { }
        $ts = $null
        try { $ts = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction Stop } catch { }
        $rdpTcp = $null
        try { $rdpTcp = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction Stop } catch { }
        [pscustomobject]@{
            build = "$($os.Version)"
            last_boot = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            uptime_days = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
            user = "$($cs.UserName)"
            ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            c_size_gb = if ($disk) { [math]::Round($disk.Size / 1GB, 1) } else { $null }
            c_free_gb = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { $null }
            c_free_pct = if ($disk -and $disk.Size) { [int][math]::Round(100 * $disk.FreeSpace / $disk.Size) } else { $null }
            pending_reboot = ($reasons.Count -gt 0)
            reboot_reasons = @($reasons)
            last_hotfix = if ($hf) { $hf.InstalledOn.ToUniversalTime().ToString('o') } else { $null }
            patch_age_days = if ($hf) { [int]((Get-Date) - $hf.InstalledOn).TotalDays } else { $null }
            defender_rt = if ($mp) { [bool]$mp.RealTimeProtectionEnabled } else { $null }
            defender_sig_age_days = if ($mp) { [int]$mp.AntivirusSignatureAge } else { $null }
            bitlocker = switch ($bl) { 1 { 'on' } 0 { 'off' } 2 { 'unknown' } default { $null } }
            rdp = if ($ts) { $ts.fDenyTSConnections -eq 0 } else { $null }
            nla = if ($rdpTcp) { $rdpTcp.UserAuthentication -eq 1 } else { $null }
        }
    }
    $byHost = @{}
    foreach ($p in $probe.items) { $byHost[$p['host'].ToLower()] = $p }
    $errByHost = @{}
    foreach ($e in $probe.errors) { $errByHost[$e.host.ToLower()] = $e.message }
    $items = @(foreach ($comp in $ad) {
        $key = if ($comp.DNSHostName) { $comp.DNSHostName.ToLower() } else { $comp.Name.ToLower() }
        $row = @{
            name = $comp.Name
            dns = $comp.DNSHostName
            os = $comp.OperatingSystem
            os_version = $comp.OperatingSystemVersion
            ou = (Get-ParentDn $comp.DistinguishedName)
            enabled = [bool]$comp.Enabled
            last_logon = (Iso $comp.LastLogonDate)
            online = $byHost.ContainsKey($key)
            error = $errByHost[$key]
        }
        if ($byHost.ContainsKey($key)) {
            foreach ($k in $byHost[$key].Keys) { if ($k -ne 'host') { $row[$k] = $byHost[$key][$k] } }
        }
        $row
    })
    @{ taken_at = (Get-Date).ToUniversalTime().ToString('o'); items = $items }
}
