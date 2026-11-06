param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        $out = (& wbadmin.exe stop job -quiet 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $(if ($out.Length -gt 400) { $out.Substring($out.Length - 400) } else { $out }) }
    }
    if (-not $r.ok) { throw "wbadmin stop job failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; cancelled = $true }
}
