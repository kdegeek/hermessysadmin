param()
Invoke-Op {
    $links = @{}
    $containers = @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase (Get-ADDomain).DistinguishedName -Properties gPLink)
    $containers += @(Get-ADObject -LDAPFilter '(gPLink=*)' -SearchBase ('CN=Sites,' + (Get-ADRootDSE).configurationNamingContext) -Properties gPLink -ErrorAction SilentlyContinue)
    foreach ($c in $containers) {
        $entries = [regex]::Matches("$($c.gPLink)", '\[LDAP://[Cc][Nn]=(\{[0-9A-Fa-f-]+\})[^;]*;(\d)\]')
        $order = $entries.Count
        foreach ($m in $entries) {
            $guid = $m.Groups[1].Value.ToUpper()
            $flag = [int]$m.Groups[2].Value
            if (-not $links.ContainsKey($guid)) { $links[$guid] = @() }
            $links[$guid] += @{ target = $c.DistinguishedName; enabled = (($flag -band 1) -eq 0); enforced = (($flag -band 2) -ne 0); order = $order }
            $order--
        }
    }
    $items = @(Get-GPO -All | Sort-Object DisplayName | ForEach-Object {
        $guid = '{' + $_.Id.ToString().ToUpper() + '}'
        @{
            id               = $_.Id.ToString()
            name             = $_.DisplayName
            status           = "$($_.GpoStatus)"
            owner            = $_.Owner
            created          = (Iso $_.CreationTime)
            modified         = (Iso $_.ModificationTime)
            description      = "$($_.Description)"
            wmi_filter       = $(if ($_.WmiFilter) { $_.WmiFilter.Name } else { $null })
            user_version     = @{ ad = $_.User.DSVersion; sysvol = $_.User.SysvolVersion }
            computer_version = @{ ad = $_.Computer.DSVersion; sysvol = $_.Computer.SysvolVersion }
            links            = @($(if ($links.ContainsKey($guid)) { $links[$guid] } else { @() }))
        }
    })
    @{ items = $items }
}
