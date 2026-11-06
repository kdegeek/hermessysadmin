param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string[]]$Members
)
Invoke-Op {
    $netbios = (Get-ADDomain).NetBIOSName
    $qualified = @($Members | ForEach-Object { if ($_ -match '\\') { $_ } else { "$netbios\$_" } })
    $short = $ComputerName.Split('.')[0]
    $isDc = @(Get-ADDomainController -Filter * | Where-Object { $_.Name -eq $short }).Count -gt 0
    if ($isDc) {
        # DCs have no local groups: their Remote Desktop Users is the domain's BUILTIN group.
        Add-ADGroupMember -Identity 'S-1-5-32-555' -Members @($Members | ForEach-Object { $_.Split('\')[-1] })
        $now = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$netbios\$($_.SamAccountName)" })
    } else {
        $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @(, $qualified) -Script {
            param($M)
            foreach ($x in $M) {
                try { Add-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberExistsException] { }
            }
            [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" }) }
        }
        $now = @($r.members)
    }
    @{ host = $ComputerName; added = $qualified; domain_controller = $isDc; members = $now }
}
