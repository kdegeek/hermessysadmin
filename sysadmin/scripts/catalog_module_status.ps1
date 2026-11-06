param(
    [Parameter(Mandatory)][string]$Lock
)
Invoke-Op {
    $mods = @((ConvertFrom-Json -InputObject $Lock).modules)
    $root = Join-Path $env:ProgramData 'HermesSysadmin\Modules'
    $recorded = @{}
    $file = Join-Path $root 'installed.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $recorded[$p.Name] = $p.Value }
        } catch { $recorded = @{} }
    }
    $items = @(foreach ($m in $mods) {
        $dir = Join-Path $root (Join-Path $m.name $m.version)
        $installed = Test-Path -LiteralPath $dir
        $rec = $recorded[$m.name]
        $verified = ($installed -and $null -ne $rec -and "$($rec.version)" -eq "$($m.version)" -and "$($rec.package_hash)" -eq "$($m.package_hash)")
        $signerOk = $null
        if ($installed -and $m.signer) {
            $signerOk = $true
            $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Extension -in @('.psd1', '.psm1', '.ps1') })
            if ($files.Count -eq 0) { $signerOk = $false }
            foreach ($f in $files) {
                $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
                if ("$($sig.Status)" -ne 'Valid' -or -not $sig.SignerCertificate -or -not $sig.SignerCertificate.Subject.Contains($m.signer)) { $signerOk = $false; break }
            }
        }
        @{ name = $m.name; version = $m.version; installed = [bool]$installed; verified = [bool]$verified; signer_ok = $signerOk }
    })
    @{ root = $root; items = $items }
}
