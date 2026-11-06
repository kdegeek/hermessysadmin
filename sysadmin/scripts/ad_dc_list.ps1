param()
Invoke-Op {
    $domain = Get-ADDomain
    $forest = Get-ADForest
    $items = @(Get-ADDomainController -Filter * | Sort-Object Name | ForEach-Object {
        @{
            name              = $_.Name
            hostname          = $_.HostName
            site              = $_.Site
            ipv4              = $_.IPv4Address
            os                = $_.OperatingSystem
            is_global_catalog = [bool]$_.IsGlobalCatalog
            is_read_only      = [bool]$_.IsReadOnly
            roles             = @($_.OperationMasterRoles | ForEach-Object { "$_" })
        }
    })
    @{ domain = $domain.DNSRoot; forest = $forest.Name; items = $items }
}
