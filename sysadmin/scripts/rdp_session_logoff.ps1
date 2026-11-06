param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][int]$SessionId,
    [switch]$Preview
)
Invoke-Op {
    if ($Preview) {
        $r = Invoke-HermesOne -Computer $ComputerName -Script {
            [pscustomobject]@{ lines = @(& quser.exe 2>&1 | ForEach-Object { "$_" }) }
        }
        return @{
            summary = "Log off session $SessionId on $ComputerName (unsaved work in that session is lost)"
            changes = @("logoff.exe $SessionId")
            current = @{ sessions = @($r.lines) }
        }
    }
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($SessionId) -Script {
        param($Id)
        $out = (& logoff.exe $Id 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "logoff failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session_id = $SessionId; logged_off = $true }
}
