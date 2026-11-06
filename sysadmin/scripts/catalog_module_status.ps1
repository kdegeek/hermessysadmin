param(
    [Parameter(Mandatory)][string]$Lock
)
Invoke-Op {
    $mods = @((ConvertFrom-Json -InputObject $Lock).modules)
    $root = Join-Path $env:ProgramData 'HermesSysadmin\Modules'
    $st = Get-HermesModuleRootState
    $rootSafe = $null
    if ($st.state -eq 'ok') { $rootSafe = $true } elseif ($st.state -ne 'missing') { $rootSafe = $false }
    $items = @(foreach ($m in $mods) {
        $dir = Join-Path $root (Join-Path $m.name $m.version)
        $installed = Test-Path -LiteralPath $dir
        # "verified" = root is admin-only, installed.json matches the pin, and every installed file still has its install-time SHA256.
        $verified = Test-HermesModuleVerified -Name $m.name -Version $m.version -PackageHash $m.package_hash
        $signerOk = $null
        if ($rootSafe -eq $true -and $installed -and $m.signer) {
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
    @{ root = $root; root_safe = $rootSafe; root_reason = $st.reason; items = $items }
}
