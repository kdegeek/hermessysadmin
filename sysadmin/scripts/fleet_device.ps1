param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
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
        $admins = @()
        try { $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { "$($_.Name)" }) } catch { }
        $procs = @(Get-Process -ErrorAction SilentlyContinue)
        $topCpu = @($procs | Where-Object { $null -ne $_.CPU } | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
            @{ name = "$($_.ProcessName)"; pid = [int]$_.Id; cpu_s = [math]::Round([double]$_.CPU, 1); ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 0) } })
        $topMem = @($procs | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
            @{ name = "$($_.ProcessName)"; pid = [int]$_.Id; cpu_s = [math]::Round([double]$_.CPU, 1); ws_mb = [math]::Round($_.WorkingSet64 / 1MB, 0) } })
        $stopped = @()
        try { $stopped = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -ErrorAction Stop | ForEach-Object { @{ name = "$($_.Name)"; display = "$($_.DisplayName)" } }) } catch { }
        $errors = @()
        try {
            $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 10 -ErrorAction Stop | ForEach-Object {
                $m = "$($_.Message)"
                if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
                @{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); log = "$($_.LogName)"; source = "$($_.ProviderName)"; id = [int]$_.Id; message = $m } })
        } catch { }
        $sw = 0
        try {
            foreach ($path in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') {
                $sw += @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }).Count
            }
        } catch { }
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
            admins = @($admins)
            top_cpu = @($topCpu)
            top_mem = @($topMem)
            stopped_auto_services = @($stopped)
            recent_errors = @($errors)
            software_count = [int]$sw
        }
    }
    $row = @{}
    foreach ($k in $r.Keys) { if ($k -ne 'host') { $row[$k] = $r[$k] } }
    $short = ($ComputerName -split '\.')[0]
    $comp = Get-ADComputer -Filter "Name -eq '$($short -replace "'", "''")'" -Properties DNSHostName, OperatingSystem, OperatingSystemVersion, LastLogonDate, Enabled, DistinguishedName | Select-Object -First 1
    $row['name'] = if ($comp) { $comp.Name } else { $short }
    $row['dns'] = if ($comp) { $comp.DNSHostName } else { $ComputerName }
    $row['os'] = if ($comp) { $comp.OperatingSystem } else { $null }
    $row['os_version'] = if ($comp) { $comp.OperatingSystemVersion } else { $null }
    $row['ou'] = if ($comp) { Get-ParentDn $comp.DistinguishedName } else { $null }
    $row['enabled'] = if ($comp) { [bool]$comp.Enabled } else { $null }
    $row['last_logon'] = if ($comp) { Iso $comp.LastLogonDate } else { $null }
    $row['online'] = $true
    $row['error'] = $null
    $row
}
