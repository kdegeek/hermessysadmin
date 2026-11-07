param()
Invoke-Op {
    # Describes the machine PowerShell runs on: the jump host over WinRM, this machine on the local transport.
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $groups = @($id.Groups | ForEach-Object {
        try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $null }
    } | Where-Object { $_ })
    # The identity a domain controller sees. On the local transport with 'Run as: account' this is the chosen
    # account (runas /netonly), and a wrong password first shows up here.
    $dc = $null
    $netName = $null
    $netError = $null
    try {
        $dc = Get-HermesDc
        $net = Invoke-HermesOnDc -Script {
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            [pscustomobject]@{
                name   = $me.Name
                groups = @($me.Groups | ForEach-Object { try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $null } } | Where-Object { $_ })
            }
        }
        $netName = "$($net.name)"
        if (@($net.groups).Count -gt 0) { $groups = @($net.groups | ForEach-Object { "$_" }) }
    } catch {
        $netError = "$($_.Exception.Message)"
    }
    @{
        hostname               = $env:COMPUTERNAME
        os                     = $os.Caption
        os_version             = $os.Version
        domain                 = $cs.Domain
        is_domain_controller   = ($cs.DomainRole -ge 4)
        ps_version             = "$($PSVersionTable.PSVersion)"
        identity               = $id.Name
        network_identity       = $netName
        network_identity_error = $netError
        dc                     = $dc
        groups                 = $groups
        modules                = @{
            ActiveDirectory     = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
            GroupPolicy         = [bool](Get-Module -ListAvailable -Name GroupPolicy)
            WindowsServerBackup = [bool](Get-Module -ListAvailable -Name WindowsServerBackup)
        }
    }
}
