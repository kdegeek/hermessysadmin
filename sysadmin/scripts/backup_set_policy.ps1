param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Schedule,
    [Parameter(Mandatory)][string]$Target,
    [bool]$SystemState = $true,
    [bool]$BareMetal = $false,
    [string[]]$Volumes = @(),
    [switch]$Preview
)
Invoke-Op {
    foreach ($t in $Schedule) { Assert-Hermes ($t -match '^([01]?\d|2[0-3]):[0-5]\d$') "Schedule time '$t' must be HH:mm." }
    Assert-Hermes ($SystemState -or $BareMetal -or $Volumes.Count -gt 0) 'The policy must back up something.'
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($Schedule, $Target, $SystemState, $BareMetal, $Volumes, $Global:HermesCred, [bool]$Preview) -Script {
        param($Sch, $T, $SS, $BMR, $V, $C, $Pv)
        Import-Module WindowsServerBackup -ErrorAction Stop
        $cur = Get-WBPolicy -ErrorAction SilentlyContinue
        $current = [pscustomobject]@{ configured = $false }
        if ($cur) {
            $current = [pscustomobject]@{
                configured   = $true
                schedule     = @(Get-WBSchedule -Policy $cur | ForEach-Object { ([datetime]$_).ToString('HH:mm') })
                target       = (@(Get-WBBackupTarget -Policy $cur) | ForEach-Object { if ($_.Path) { "$($_.Path)" } else { "$($_.Label)" } }) -join ', '
                system_state = [bool](Get-WBSystemState -Policy $cur)
                bare_metal   = [bool](Get-WBBareMetalRecovery -Policy $cur)
                volumes      = @(Get-WBVolume -Policy $cur | ForEach-Object { "$($_.MountPath)" })
            }
        }
        if ($Pv) { return [pscustomobject]@{ current = $current } }
        $p = New-WBPolicy
        if ($SS) { Add-WBSystemState -Policy $p }
        if ($BMR) { Add-WBBareMetalRecovery -Policy $p }
        foreach ($vol in $V) { Add-WBVolume -Policy $p -Volume (Get-WBVolume -VolumePath $vol) }
        Set-WBSchedule -Policy $p -Schedule @($Sch | ForEach-Object { [datetime]::ParseExact($_, 'H:mm', [cultureinfo]::InvariantCulture) }) | Out-Null
        if ($T -like '\\*') {
            # $C is the WinRM service credential; $null on the local transport, so the schedule then authenticates
            # to the share as the server's computer account.
            $wb = @{ NetworkPath = $T }
            if ($C) { $wb.Credential = $C }
            $bt = New-WBBackupTarget @wb
        } else { $bt = New-WBBackupTarget -VolumePath $T }
        Add-WBBackupTarget -Policy $p -Target $bt | Out-Null
        Set-WBPolicy -Policy $p -Force
        [pscustomobject]@{ current = $current }
    }
    $wanted = @{ schedule = @($Schedule); target = $Target; system_state = $SystemState; bare_metal = $BareMetal; volumes = @($Volumes) }
    $before = @{}
    foreach ($prop in $r.current.PSObject.Properties) { $before[$prop.Name] = $prop.Value }
    if ($Preview) {
        return @{
            summary = "Replace the scheduled backup policy on $ComputerName"
            changes = @(
                "Schedule: $(@($before.schedule) -join ', ') -> $($Schedule -join ', ')",
                "Target: $($before.target) -> $Target",
                "System state: $($before.system_state) -> $SystemState; bare metal: $($before.bare_metal) -> $BareMetal",
                "Volumes: $(@($before.volumes) -join ', ') -> $(@($Volumes) -join ', ')",
                "Set-WBPolicy -Force (replaces the existing policy)"
            ) + @(if ($Target -like '\\*' -and -not $Global:HermesCred) {
                "UNC target with no stored credential: the scheduled backup writes to $Target as the computer account of $ComputerName, which needs write access to the share"
            })
            current = $before
        }
    }
    @{ host = $ComputerName; previous = $before; policy = $wanted }
}
