param(
    [Parameter(Mandatory)][string]$Identity,
    [int]$Hours = 24
)
Invoke-Op {
    $u = Get-ADUser -Identity $Identity -Properties LockedOut, lockoutTime
    $pdc = (Get-ADDomain).PDCEmulator
    $byDc = @(foreach ($dc in @(Get-ADDomainController -Filter * | ForEach-Object { $_.HostName })) {
        try {
            $x = Get-ADUser -Identity $u.SamAccountName -Server $dc -Properties badPwdCount, badPasswordTime
            @{ dc = $dc; count = $x.badPwdCount; last = $(if ($x.badPasswordTime) { [datetime]::FromFileTimeUtc($x.badPasswordTime).ToString('o') } else { $null }) }
        } catch {
            @{ dc = $dc; count = $null; last = $null; error = "$($_.Exception.Message)" }
        }
    })
    $remote = Get-HermesFanout -Computers @($pdc) -ArgumentList @($u.SamAccountName, $Hours) -Script {
        param($Sam, $H)
        $start = (Get-Date).AddHours(-$H)
        Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = $start } -ErrorAction SilentlyContinue |
            Where-Object { $_.Properties[0].Value -eq $Sam } |
            Select-Object -First 200 |
            ForEach-Object { [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); source = "$($_.Properties[1].Value)" } }
    }
    @{
        identity           = $u.SamAccountName
        locked             = [bool]$u.LockedOut
        lockout_time       = $(if ($u.lockoutTime) { [datetime]::FromFileTimeUtc($u.lockoutTime).ToString('o') } else { $null })
        pdc                = $pdc
        hours              = $Hours
        events             = @($remote.results | ForEach-Object { @{ time = $_.time; source = $_.source; dc = $_.host } })
        bad_password_by_dc = $byDc
        errors             = $remote.errors
    }
}
