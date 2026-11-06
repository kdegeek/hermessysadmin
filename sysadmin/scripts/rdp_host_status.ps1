param(
    [string[]]$Hosts = @(),
    [string]$Ou,
    [string]$ServerSearchBase
)
Invoke-Op {
    $targets = @(Get-HermesTargets -Computers $Hosts -Ou $Ou -SearchBase $ServerSearchBase)
    Assert-Hermes ($targets.Count -gt 0) 'No target computers found.'
    $remote = Get-HermesFanout -Computers $targets -Script {
        $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $tcp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        # '@FirewallAPI.dll,-28752' is the locale-independent name of the "Remote Desktop" rule group.
        $fw = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue)
        $members = $null
        try { $members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop | ForEach-Object { "$($_.Name)" }) } catch { $members = $null }
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            enabled       = ($ts.fDenyTSConnections -eq 0)
            nla           = ($tcp.UserAuthentication -eq 1)
            port          = [int]$tcp.PortNumber
            firewall_open = (@($fw | Where-Object { "$($_.Enabled)" -eq 'True' }).Count -gt 0)
            rdp_users     = $members
            os            = "$($os.Caption)"
            last_boot     = $os.LastBootUpTime.ToUniversalTime().ToString('o')
        }
    }
    @{ results = $remote.results; errors = $remote.errors; targets = $targets.Count }
}
