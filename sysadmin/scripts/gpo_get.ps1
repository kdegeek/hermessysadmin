param([Parameter(Mandatory)][string]$Identity)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $guid = '{' + $gpo.Id.ToString().ToUpper() + '}'
    $links = @()
    $containers = @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" -Properties gPLink)
    $containers += @(Get-ADObject -LDAPFilter "(gPLink=*$guid*)" -SearchBase ('CN=Sites,' + (Get-ADRootDSE).configurationNamingContext) -Properties gPLink -ErrorAction SilentlyContinue)
    foreach ($c in $containers) {
        foreach ($m in [regex]::Matches("$($c.gPLink)", '\[LDAP://[Cc][Nn]=(\{[0-9A-Fa-f-]+\})[^;]*;(\d)\]')) {
            if ($m.Groups[1].Value.ToUpper() -ne $guid) { continue }
            $flag = [int]$m.Groups[2].Value
            $links += @{ target = $c.DistinguishedName; enabled = (($flag -band 1) -eq 0); enforced = (($flag -band 2) -ne 0) }
        }
    }
    $perms = @(Get-GPPermission -Guid $gpo.Id -All)
    @{
        id                 = $gpo.Id.ToString()
        name               = $gpo.DisplayName
        status             = "$($gpo.GpoStatus)"
        owner              = $gpo.Owner
        description        = "$($gpo.Description)"
        created            = (Iso $gpo.CreationTime)
        modified           = (Iso $gpo.ModificationTime)
        wmi_filter         = $(if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { $null })
        user_version       = @{ ad = $gpo.User.DSVersion; sysvol = $gpo.User.SysvolVersion }
        computer_version   = @{ ad = $gpo.Computer.DSVersion; sysvol = $gpo.Computer.SysvolVersion }
        links              = $links
        security_filtering = @($perms | Where-Object { "$($_.Permission)" -eq 'GpoApply' } | ForEach-Object { "$($_.Trustee.Name)" })
        delegation         = @($perms | Where-Object { "$($_.Permission)" -ne 'GpoApply' } | ForEach-Object { @{ trustee = "$($_.Trustee.Name)"; permission = "$($_.Permission)" } })
    }
}
