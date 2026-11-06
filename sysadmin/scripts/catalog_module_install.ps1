param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Lock,
    [switch]$Preview
)
Invoke-Op {
    $ProgressPreference = 'SilentlyContinue'
    $mods = @((ConvertFrom-Json -InputObject $Lock).modules)
    $byName = @{}
    foreach ($m in $mods) {
        Assert-Hermes ("$($m.name)" -match '^[A-Za-z0-9._-]+$') "Lock entry has an invalid module name '$($m.name)'."
        Assert-Hermes ("$($m.version)" -match '^\d+(\.\d+){1,3}$') "Lock entry $($m.name) has an invalid version '$($m.version)'."
        $byName[$m.name] = $m
    }
    foreach ($m in $mods) {
        foreach ($r in @($m.requires)) { Assert-Hermes ($r -and $byName.ContainsKey($r)) "Lock entry $($m.name) requires '$r', which is not in the lock." }
    }
    Assert-Hermes ($byName.ContainsKey($Name)) "'$Name' is not a pinned module."

    # Dependencies first; $state is 1 while visiting (a revisit is a cycle) and 2 when done.
    $order = New-Object System.Collections.ArrayList
    $state = @{}
    $visit = $null
    $visit = {
        param([string]$n)
        if ($state[$n] -eq 2) { return }
        if ($state[$n] -eq 1) { throw "The lock has a dependency cycle at '$n'." }
        $state[$n] = 1
        foreach ($r in @($byName[$n].requires)) { if ($r) { & $visit $r } }
        $state[$n] = 2
        [void]$order.Add($n)
    }
    & $visit $Name

    $root = Join-Path $env:ProgramData 'HermesSysadmin\Modules'
    $stagingDir = Join-Path $root 'staging'
    $recordFile = Join-Path $root 'installed.json'
    $arrow = [string][char]0x2192

    if ($Preview) {
        $rootNote = @()
        $st = Get-HermesModuleRootState
        if ($st.state -eq 'missing') { $rootNote = @("Create $root with an administrators-only ACL") }
        elseif ($st.state -eq 'broad') { $rootNote = @("Existing module root will be re-secured (administrators-only ACL): $($st.reason)") }
        elseif ($st.state -eq 'foreign') { $rootNote = @("Existing module root fails the safety check and the install will refuse to run: $($st.reason)") }
        $lines = @(foreach ($n in $order) {
            $m = $byName[$n]
            $dest = Join-Path $root (Join-Path $m.name $m.version)
            $staged = Join-Path $stagingDir "$($m.name).$($m.version).nupkg"
            if (Test-HermesModuleVerified -Name $m.name -Version $m.version -PackageHash $m.package_hash) { "$($m.name) $($m.version): already installed" }
            elseif (Test-Path -LiteralPath $staged) { "Use staged package $staged $arrow verify SHA512 $arrow install to $dest" }
            else { "Download https://www.powershellgallery.com/api/v2/package/$($m.name)/$($m.version) $arrow verify SHA512 $arrow install to $dest" }
        })
        $current = @(foreach ($n in $order) {
            $m = $byName[$n]
            @{
                name = $m.name; version = $m.version
                installed = [bool](Test-Path -LiteralPath (Join-Path $root (Join-Path $m.name $m.version)))
                verified = [bool](Test-HermesModuleVerified -Name $m.name -Version $m.version -PackageHash $m.package_hash)
            }
        })
        return @{
            summary = "Install $Name and its pinned dependencies ($($order.Count) module(s)) into $root"
            changes = @($rootNote + $lines)
            current = @{ root = $root; items = $current }
        }
    }

    [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Assert-HermesModuleRoot -Create
    Assert-HermesModuleRoot
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    $record = Get-HermesModuleRecord
    $results = @()
    foreach ($n in $order) {
        $m = $byName[$n]
        if (Test-HermesModuleVerified -Name $m.name -Version $m.version -PackageHash $m.package_hash) {
            $results += @{ name = $m.name; version = $m.version; action = 'already installed' }
            continue
        }
        $staged = Join-Path $stagingDir "$($m.name).$($m.version).nupkg"
        $part = "$staged.part"
        $tmp = Join-Path $root ('.tmp-' + [guid]::NewGuid().ToString('N'))
        try {
            if (-not (Test-Path -LiteralPath $staged)) {
                $url = "https://www.powershellgallery.com/api/v2/package/$($m.name)/$($m.version)"
                try {
                    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $part
                    Move-Item -LiteralPath $part -Destination $staged
                } catch {
                    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                    throw
                }
            }
            # Hash and extract the SAME private copy, so the staged file cannot be swapped in between.
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            $work = Join-Path $tmp 'package.nupkg'
            $content = Join-Path $tmp 'content'
            Copy-Item -LiteralPath $staged -Destination $work
            $hex = (Get-FileHash -LiteralPath $work -Algorithm SHA512).Hash
            $bytes = [byte[]]@($hex -split '(?<=\G..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
            $actual = [Convert]::ToBase64String($bytes)
            if ($actual -cne $m.package_hash) {
                Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue
                throw "$($m.name) $($m.version): package SHA512 does not match the pinned hash; the download was deleted."
            }
            [IO.Compression.ZipFile]::ExtractToDirectory($work, $content)
            foreach ($junk in @('_rels', 'package')) { Remove-Item -LiteralPath (Join-Path $content $junk) -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath (Join-Path $content '[Content_Types].xml') -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $content -Filter '*.nuspec' -File | Remove-Item -Force
            if ($m.signer) {
                $files = @(Get-ChildItem -LiteralPath $content -Recurse -File | Where-Object { $_.Extension -in @('.psd1', '.psm1', '.ps1') })
                if ($files.Count -eq 0) { throw "$($m.name) $($m.version): no script files to verify the signature of." }
                foreach ($f in $files) {
                    $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
                    if ("$($sig.Status)" -ne 'Valid') { throw "$($m.name) $($m.version): $($f.Name) signature is $($sig.Status)." }
                    if (-not $sig.SignerCertificate -or -not $sig.SignerCertificate.Subject.Contains($m.signer)) { throw "$($m.name) $($m.version): $($f.Name) is not signed by $($m.signer)." }
                }
            }
            $fileHashes = Get-HermesFileHashMap -Dir $content
            $dest = Join-Path $root (Join-Path $m.name $m.version)
            New-Item -ItemType Directory -Path (Join-Path $root $m.name) -Force | Out-Null
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Move-Item -LiteralPath $content -Destination $dest
            $record[$m.name] = @{ version = "$($m.version)"; package_hash = "$($m.package_hash)"; installed_utc = (Get-Date).ToUniversalTime().ToString('o'); files = $fileHashes }
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordFile -Encoding UTF8
            $results += @{ name = $m.name; version = $m.version; action = 'installed'; path = $dest }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    @{ requested = $Name; root = $root; modules = $results }
}
