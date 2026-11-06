param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [Parameter(Mandatory)][bool]$Enabled,
    [switch]$Preview
)
Invoke-Op {
    $verb = if ($Enabled) { 'Enable' } else { 'Disable' }
    if ($Preview) {
        $remote = Get-HermesFanout -Computers $Hosts -Script {
            $ts = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            [pscustomobject]@{ enabled = ($ts.fDenyTSConnections -eq 0) }
        }
        return @{
            summary = "$verb Remote Desktop on $($Hosts.Count) host(s)"
            changes = @("fDenyTSConnections = $([int](-not $Enabled))", "$verb-NetFirewallRule -Group 'Remote Desktop'")
            current = @{ hosts = $remote.results; unreachable = $remote.errors }
        }
    }
    $remote = Get-HermesFanout -Computers $Hosts -ArgumentList @($Enabled) -Script {
        param($On)
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ([int](-not $On))
        if ($On) { Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' } else { Disable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' }
        [pscustomobject]@{ enabled = [bool]$On }
    }
    @{ results = $remote.results; errors = $remote.errors }
}
