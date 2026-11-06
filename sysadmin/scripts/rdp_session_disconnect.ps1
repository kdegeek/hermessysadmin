param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][int]$SessionId
)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($SessionId) -Script {
        param($Id)
        $out = (& tsdiscon.exe $Id 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "tsdiscon failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session_id = $SessionId; disconnected = $true }
}
