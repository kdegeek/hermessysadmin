param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        [pscustomobject]@{ lines = @(quser 2>$null | ForEach-Object { "$_" }) }
    }
}
