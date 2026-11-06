param(
    [Parameter(Mandatory)][string]$ComputerName,
    [Parameter(Mandatory)][string]$Message,
    [Nullable[int]]$SessionId = $null,
    [int]$Seconds = 60
)
Invoke-Op {
    Assert-Hermes ($Message.Length -le 255) 'Message must be 255 characters or fewer.'
    $target = if ($null -ne $SessionId) { "$SessionId" } else { '*' }
    # Arguments are passed as separate argv entries, never through a shell.
    $r = Invoke-HermesOne -Computer $ComputerName -ArgumentList @($target, $Seconds, $Message) -Script {
        param($T, $S, $M)
        $out = (& msg.exe $T "/TIME:$S" $M 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); output = $out }
    }
    if (-not $r.ok) { throw "msg failed on ${ComputerName}: $($r.output)" }
    @{ host = $ComputerName; session = $target; sent = $true }
}
