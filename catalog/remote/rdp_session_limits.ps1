<# hermes-catalog
id: remote.rdp_session_limits
title: Remote Desktop session time limits
category: Remote access
description: Remote Desktop session limits in minutes, idle limit, disconnected-session limit and active-session limit (0 means never), whether a session ends rather than disconnects when a limit is hit, and whether each user is held to one session. Group Policy values win over the RDP-Tcp listener's own; source says whether any policy value applied. An empty limit means the listener takes it from each user's account settings.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, idle_minutes, disconnected_minutes, active_minutes, end_on_limit, single_session, source]
tags: [rdp, remote desktop, session limits, idle timeout, disconnected sessions, time limits, single session]
source: In-box registry (Terminal Services policy, Terminal Server and RDP-Tcp)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -ErrorAction SilentlyContinue
        $tcp = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue
        $ts = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue
        $st = @{ src = 'local' }
        function Get-Limit([string]$Name, [string]$Inherit) {
            $v = $null
            if ($pol -and $null -ne $pol.$Name) { $v = $pol.$Name; $st.src = 'policy' }
            elseif ($tcp -and $null -ne $tcp.$Name) {
                if ($null -ne $tcp.$Inherit -and [int]$tcp.$Inherit -eq 1) { return $null }
                $v = $tcp.$Name
            }
            if ($null -eq $v) { return 0 }
            return [int][math]::Floor(([int64]$v -band [int64]4294967295) / 60000)
        }
        $idle = Get-Limit 'MaxIdleTime' 'fInheritMaxIdleTime'
        $disc = Get-Limit 'MaxDisconnectionTime' 'fInheritMaxDisconnectionTime'
        $act = Get-Limit 'MaxConnectionTime' 'fInheritMaxSessionTime'
        $reset = $null
        if ($pol -and $null -ne $pol.fResetBroken) { $reset = ([int]$pol.fResetBroken -eq 1); $st.src = 'policy' }
        elseif ($tcp -and $null -ne $tcp.fResetBroken -and -not ($null -ne $tcp.fInheritResetBroken -and [int]$tcp.fInheritResetBroken -eq 1)) { $reset = ([int]$tcp.fResetBroken -eq 1) }
        $single = $null
        if ($pol -and $null -ne $pol.fSingleSessionPerUser) { $single = ([int]$pol.fSingleSessionPerUser -eq 1); $st.src = 'policy' }
        elseif ($ts -and $null -ne $ts.fSingleSessionPerUser) { $single = ([int]$ts.fSingleSessionPerUser -eq 1) }
        [pscustomobject]@{ idle_minutes = $idle; disconnected_minutes = $disc; active_minutes = $act; end_on_limit = $reset; single_session = $single; source = $st.src }
    }
}
