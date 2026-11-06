param(
    [string[]]$Computers = @(),
    [string]$Ou,
    [bool]$Force = $true
)
Invoke-Op {
    $targets = @($Computers)
    if ($Ou) { $targets += @(Get-ADComputer -Filter * -SearchBase $Ou -Properties DNSHostName | ForEach-Object { $_.DNSHostName } | Where-Object { $_ }) }
    $targets = @($targets | Sort-Object -Unique)
    Assert-Hermes ($targets.Count -gt 0) 'Give computers or an OU that contains computers.'
    $remote = Get-HermesFanout -Computers $targets -ArgumentList @($Force) -Script {
        param($F)
        $gpArgs = @('/target:computer')
        if ($F) { $gpArgs += '/force' }
        $out = (& gpupdate.exe @gpArgs 2>&1 | Out-String).Trim()
        [pscustomobject]@{
            ok        = ($LASTEXITCODE -eq 0)
            exit_code = $LASTEXITCODE
            output    = $(if ($out.Length -gt 400) { $out.Substring($out.Length - 400) } else { $out })
        }
    }
    @{ targets = $targets.Count; results = $remote.results; errors = $remote.errors }
}
