param()
Invoke-Op {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $groups = @($id.Groups | ForEach-Object {
        try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { $null }
    } | Where-Object { $_ })
    @{
        hostname             = $env:COMPUTERNAME
        os                   = $os.Caption
        os_version           = $os.Version
        domain               = $cs.Domain
        is_domain_controller = ($cs.DomainRole -ge 4)
        ps_version           = "$($PSVersionTable.PSVersion)"
        identity             = $id.Name
        groups               = $groups
        modules              = @{
            ActiveDirectory     = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
            GroupPolicy         = [bool](Get-Module -ListAvailable -Name GroupPolicy)
            WindowsServerBackup = [bool](Get-Module -ListAvailable -Name WindowsServerBackup)
        }
    }
}
