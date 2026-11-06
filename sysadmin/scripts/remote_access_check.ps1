param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        $ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
        $deny = $null
        try { $deny = (Get-ItemProperty $ts -ErrorAction Stop).fDenyTSConnections } catch { }
        $nla = $null
        try { $nla = (Get-ItemProperty "$ts\WinStations\RDP-Tcp" -ErrorAction Stop).UserAuthentication } catch { }
        $rdpFw = $null
        try { $rdpFw = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }).Count -gt 0 } catch { }
        $users = @()
        try { $users = @(Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop | ForEach-Object { "$($_.Name)" }) } catch { }
        $shadow = $null
        try { $shadow = [int](Get-ItemProperty $pol -ErrorAction Stop).Shadow } catch { }
        $unsol = $null
        try { $unsol = ([int](Get-ItemProperty $pol -ErrorAction Stop).fAllowUnsolicited) -eq 1 } catch { $unsol = $false }
        $raFw = $null
        try { $raFw = @(Get-NetFirewallRule -DisplayGroup 'Remote Assistance' -ErrorAction Stop | Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }).Count -gt 0 } catch { }
        [pscustomobject]@{
            rdp_enabled    = if ($null -eq $deny) { $null } else { ([int]$deny -eq 0) }
            nla            = if ($null -eq $nla) { $null } else { ([int]$nla -eq 1) }
            rdp_firewall   = $rdpFw
            rdp_users      = $users
            shadow         = $shadow
            ra_unsolicited = $unsol
            ra_firewall    = $raFw
        }
    }
    @{
        rdp_enabled = $r['rdp_enabled']; nla = $r['nla']; rdp_firewall = $r['rdp_firewall']
        rdp_users = @($r['rdp_users']); shadow = $r['shadow']
        ra_unsolicited = $r['ra_unsolicited']; ra_firewall = $r['ra_firewall']
    }
}
