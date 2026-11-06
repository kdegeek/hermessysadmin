param(
    [Parameter(Mandatory)][string]$Computer,
    [string]$User
)
Invoke-Op {
    $remote = Get-HermesFanout -Computers @($Computer) -ArgumentList @($User) -Script {
        param($U)
        $path = Join-Path $env:TEMP ('hermes-rsop-' + [guid]::NewGuid().ToString() + '.xml')
        $gpArgs = @('/x', $path, '/f')
        if ($U) { $gpArgs += @('/user', $U) } else { $gpArgs += @('/scope', 'computer') }
        $null = & gpresult.exe @gpArgs 2>&1
        if (-not (Test-Path $path)) { throw 'gpresult produced no report (for a user, they must have logged on to this computer).' }
        [xml]$x = Get-Content -Path $path -Raw
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        $read = {
            param($node)
            @(foreach ($g in @($node.GPO)) {
                if (-not $g) { continue }
                [pscustomobject]@{
                    name           = "$($g.Name)"
                    applied        = ("$($g.Enabled)" -eq 'true' -and "$($g.IsValid)" -eq 'true' -and "$($g.FilterAllowed)" -eq 'true' -and "$($g.AccessDenied)" -eq 'false')
                    filter_allowed = ("$($g.FilterAllowed)" -eq 'true')
                    access_denied  = ("$($g.AccessDenied)" -eq 'true')
                    link           = "$($g.Link.SOMPath)"
                }
            })
        }
        [pscustomobject]@{
            computer_gpos      = @(& $read $x.Rsop.ComputerResults)
            user_gpos          = @(& $read $x.Rsop.UserResults)
            computer_read_time = "$($x.Rsop.ComputerResults.ReadTime)"
            user_read_time     = "$($x.Rsop.UserResults.ReadTime)"
        }
    }
    if ($remote.errors.Count -gt 0) { throw "$($remote.errors[0].host): $($remote.errors[0].message)" }
    $r = $remote.results[0]
    @{
        computer           = $Computer
        user               = $User
        computer_gpos      = @($r.computer_gpos)
        user_gpos          = @($r.user_gpos)
        computer_read_time = $r.computer_read_time
        user_read_time     = $r.user_read_time
    }
}
