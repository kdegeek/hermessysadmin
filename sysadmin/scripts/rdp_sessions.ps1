param(
    [string[]]$Hosts = @(),
    [string]$Ou,
    [string]$User,              # filtered in Python (post)
    [string]$ServerSearchBase
)
Invoke-Op {
    $targets = @(Get-HermesTargets -Computers $Hosts -Ou $Ou -SearchBase $ServerSearchBase)
    Assert-Hermes ($targets.Count -gt 0) 'No target computers found.'
    $remote = Get-HermesFanout -Computers $targets -Script {
        [pscustomobject]@{ lines = @(& quser.exe 2>&1 | ForEach-Object { "$_" }) }
    }
    @{
        hosts   = @($remote.results | ForEach-Object { @{ host = $_.host; lines = @($_.lines) } })
        errors  = $remote.errors
        targets = $targets.Count
    }
}
