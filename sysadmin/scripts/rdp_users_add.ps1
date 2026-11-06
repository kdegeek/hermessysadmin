param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Members
)
Invoke-Op {
    $netbios = (Get-ADDomain).NetBIOSName
    $qualified = @($Members | ForEach-Object { if ($_ -match '\\') { $_ } else { "$netbios\$_" } })
    $warning = $null
    $short = $ComputerName.Split('.')[0]
    $isDc = @(Get-ADDomainController -Filter * | Where-Object { $_.Name -eq $short }).Count -gt 0
    if ($isDc) {
        # DCs have no local groups: their Remote Desktop Users is the domain's BUILTIN group.
        $have = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$($_.SamAccountName)".ToLower() })
        $todo = @($Members | ForEach-Object { $_.Split('\')[-1] } | Where-Object { $have -notcontains $_.ToLower() })
        if ($todo.Count -gt 0) { Add-ADGroupMember -Identity 'S-1-5-32-555' -Members $todo }
        try {
            $now = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$netbios\$($_.SamAccountName)" })
        } catch {
            $now = $null
            $warning = "Change applied but the membership read-back failed: $($_.Exception.Message)"
        }
    } else {
        $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @(, $qualified) -Script {
            param($M)
            foreach ($x in $M) {
                try { Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberExistsException] { }
            }
            try {
                [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' -ErrorAction Stop | ForEach-Object { "$($_.Name)" }); warning = $null }
            } catch {
                [pscustomobject]@{ members = $null; warning = "Change applied but the membership read-back failed: $($_.Exception.Message)" }
            }
        }
        $now = $null
        if ($null -ne $r.members) { $now = @($r.members) }
        $warning = $r.warning
    }
    @{ host = $ComputerName; added = $qualified; domain_controller = $isDc; members = $now; warning = $warning }
}
