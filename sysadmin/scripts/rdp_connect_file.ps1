param(
    [Parameter(Mandatory)][string]$ComputerName,
    [string]$Username,          # used in Python (post)
    [string]$Gateway            # used in Python (post)
)
Invoke-Op {
    $short = $ComputerName.Split('.')[0]
    $c = Get-ADComputer -LDAPFilter "(name=$(ConvertTo-LdapValue $short))" -Properties DNSHostName | Select-Object -First 1
    Assert-Hermes ($null -ne $c) "No computer named '$short' in Active Directory."
    @{ host = $(if ($c.DNSHostName) { $c.DNSHostName } else { $ComputerName }); computer = $c.Name }
}
