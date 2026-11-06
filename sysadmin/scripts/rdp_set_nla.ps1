param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [Parameter(Mandatory)][bool]$Required
)
Invoke-Op {
    $remote = Get-HermesFanout -Computers $Hosts -ArgumentList @($Required) -Script {
        param($On)
        $ErrorActionPreference = 'Stop'
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value ([int][bool]$On)
        [pscustomobject]@{ nla = [bool]$On }
    }
    @{ results = $remote.results; errors = $remote.errors }
}
