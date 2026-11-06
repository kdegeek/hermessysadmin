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
        $have = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$($_.SamAccountName)".ToLower() })
        $todo = @($Members | ForEach-Object { $_.Split('\')[-1] } | Where-Object { $have -contains $_.ToLower() })
        if ($todo.Count -gt 0) { Remove-ADGroupMember -Identity 'S-1-5-32-555' -Members $todo -Confirm:$false }
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
                try { Remove-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberNotFoundException] { }
            }
            try {
                [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" }); warning = $null }
            } catch {
                [pscustomobject]@{ members = $null; warning = "Change applied but the membership read-back failed: $($_.Exception.Message)" }
            }
        }
        $now = if ($null -eq $r.members) { $null } else { @($r.members) }
        $warning = $r.warning
    }
    @{ host = $ComputerName; removed = $qualified; domain_controller = $isDc; members = $now; warning = $warning }
}
