param()
Invoke-Op {
    $dcs = @(Get-ADDomainController -Filter * | Sort-Object Name)
    $pdc = "$((Get-ADDomain).PDCEmulator)"
    $refUtc = [datetime]::UtcNow
    $remote = Get-HermesFanout -Computers @($dcs | ForEach-Object { $_.HostName }) -Script {
        $svc = @{}
        foreach ($n in 'NTDS', 'DNS', 'Netlogon', 'KDC', 'W32Time') {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            $svc[$n] = if ($s) { "$($s.Status)" } else { 'Missing' }
        }
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            services        = $svc
            uptime_hours    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
            utc_now         = [datetime]::UtcNow.ToString('o')
            sysvol_shared   = [bool](Get-SmbShare -Name SYSVOL -ErrorAction SilentlyContinue)
            netlogon_shared = [bool](Get-SmbShare -Name NETLOGON -ErrorAction SilentlyContinue)
        }
    }
    $byHost = @{}
    foreach ($r in $remote.results) { $byHost["$($r.host)".ToLower()] = $r }
    # Time skew is measured against the PDC emulator (the domain time source), not against whichever
    # machine runs this session (the Hermes machine on the local transport).
    $pdcResult = $byHost[$pdc.ToLower()]
    if ($pdcResult -and $pdcResult.utc_now) { $refUtc = ([datetime]$pdcResult.utc_now).ToUniversalTime() }
    $items = @(foreach ($dc in $dcs) {
        $replError = $null
        $failures = @()
        $partners = @()
        try {
            $failures = @(Get-ADReplicationFailure -Target $dc.HostName | Where-Object { $_.FailureCount -gt 0 })
            $partners = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -Scope Server)
        } catch { $replError = "$($_.Exception.Message)" }
        $last = ($partners | Sort-Object LastReplicationSuccess -Descending | Select-Object -First 1).LastReplicationSuccess
        $r = $byHost["$($dc.HostName)".ToLower()]
        if (-not $r) { $r = $byHost["$($dc.Name)".ToLower()] }
        $skew = $null
        if ($r -and $r.utc_now) { $skew = [math]::Round((([datetime]$r.utc_now).ToUniversalTime() - $refUtc).TotalSeconds, 1) }
        @{
            name              = $dc.Name
            hostname          = $dc.HostName
            site              = $dc.Site
            roles             = @($dc.OperationMasterRoles | ForEach-Object { "$_" })
            reachable         = [bool]$r
            services          = $(if ($r) { $r.services } else { $null })
            uptime_hours      = $(if ($r) { $r.uptime_hours } else { $null })
            sysvol_shared     = $(if ($r) { $r.sysvol_shared } else { $null })
            netlogon_shared   = $(if ($r) { $r.netlogon_shared } else { $null })
            time_skew_seconds = $skew
            replication       = @{
                failures     = $failures.Count
                partners     = $partners.Count
                last_success = (Iso $last)
                error        = $replError
                errors       = @($failures | Select-Object -First 5 | ForEach-Object {
                    @{ partner = "$($_.Partner)"; count = $_.FailureCount; first = (Iso $_.FirstFailureTime); message = "$($_.LastError)" }
                })
            }
        }
    })
    @{ items = $items; errors = $remote.errors }
}
