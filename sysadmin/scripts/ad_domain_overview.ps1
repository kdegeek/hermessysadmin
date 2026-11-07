param(
    [int]$StaleDays = 90,
    [int]$ExpiringDays = 7
)
Invoke-Op {
    $d = Get-ADDomain
    $f = Get-ADForest
    $nowUtc = (Get-Date).ToUniversalTime()
    $users = @(Get-ADUser -Filter * -Properties Enabled, PasswordNeverExpires, LastLogonDate, WhenCreated, 'msDS-UserPasswordExpiryTimeComputed')
    $locked = @(Search-ADAccount -LockedOut -UsersOnly)
    $expiring = @($users | Where-Object {
        $ft = $_.'msDS-UserPasswordExpiryTimeComputed'
        $_.Enabled -and -not $_.PasswordNeverExpires -and $ft -gt 0 -and $ft -lt [long]::MaxValue -and
        [datetime]::FromFileTimeUtc($ft) -gt $nowUtc -and [datetime]::FromFileTimeUtc($ft) -lt $nowUtc.AddDays($ExpiringDays)
    })
    $userCutoff = $nowUtc.AddDays(-$StaleDays)
    $staleUsers = @($users | Where-Object {
        $_.Enabled -and (($_.LastLogonDate -and $_.LastLogonDate.ToUniversalTime() -lt $userCutoff) -or (-not $_.LastLogonDate -and $_.WhenCreated -and $_.WhenCreated.ToUniversalTime() -lt $userCutoff))
    })
    $computers = @(Get-ADComputer -Filter * -Properties LastLogonTimestamp)
    $cutoff = $nowUtc.AddDays(-$StaleDays).ToFileTimeUtc()
    $stale = @($computers | Where-Object { -not $_.LastLogonTimestamp -or $_.LastLogonTimestamp -lt $cutoff })
    $gpos = $null
    if (Get-Command Get-GPO -ErrorAction SilentlyContinue) { try { $gpos = @(Get-GPO -All).Count } catch { $gpos = $null } }
    $recycle = @(Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" | Where-Object { $_.EnabledScopes.Count -gt 0 }).Count -gt 0
    @{
        domain              = $d.DNSRoot
        netbios             = $d.NetBIOSName
        domain_mode         = "$($d.DomainMode)"
        forest              = $f.Name
        forest_mode         = "$($f.ForestMode)"
        fsmo                = @{ pdc = $d.PDCEmulator; rid = $d.RIDMaster; infrastructure = $d.InfrastructureMaster; schema = $f.SchemaMaster; naming = $f.DomainNamingMaster }
        recycle_bin_enabled = $recycle
        stale_days          = $StaleDays
        expiring_days       = $ExpiringDays
        counts              = @{
            users              = $users.Count
            users_enabled      = @($users | Where-Object { $_.Enabled }).Count
            users_disabled     = @($users | Where-Object { -not $_.Enabled }).Count
            users_locked       = $locked.Count
            users_never_expire = @($users | Where-Object { $_.PasswordNeverExpires }).Count
            users_stale        = $staleUsers.Count
            passwords_expiring = $expiring.Count
            computers          = $computers.Count
            computers_stale    = $stale.Count
            groups             = @(Get-ADGroup -Filter *).Count
            ous                = @(Get-ADOrganizationalUnit -Filter *).Count
            gpos               = $gpos
        }
    }
}
