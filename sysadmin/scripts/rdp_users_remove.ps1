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
        Remove-ADGroupMember -Identity 'S-1-5-32-555' -Members @($Members | ForEach-Object { $_.Split('\')[-1] }) -Confirm:$false
        $now = @(Get-ADGroupMember -Identity 'S-1-5-32-555' | ForEach-Object { "$netbios\$($_.SamAccountName)" })
    } else {
        $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @(, $qualified) -Script {
            param($M)
            foreach ($x in $M) {
                try { Remove-LocalGroupMember -SID 'S-1-5-32-555' -Member $x -ErrorAction Stop }
                catch [Microsoft.PowerShell.Commands.MemberNotFoundException] { }
            }
            [pscustomobject]@{ members = @(Get-LocalGroupMember -SID 'S-1-5-32-555' | ForEach-Object { "$($_.Name)" }) }
        }
        $now = @($r.members)
    }
    @{ host = $ComputerName; removed = $qualified; domain_controller = $isDc; members = $now }
}
