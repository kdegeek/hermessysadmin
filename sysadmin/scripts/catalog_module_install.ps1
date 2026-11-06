param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Lock,
    [switch]$Preview
)
Invoke-Op {
    $mods = @((ConvertFrom-Json -InputObject $Lock).modules)
    $byName = @{}
    foreach ($m in $mods) { $byName[$m.name] = $m }
    Assert-Hermes ($byName.ContainsKey($Name)) "'$Name' is not a pinned module."

    # Dependencies first.
    $order = New-Object System.Collections.ArrayList
    $visit = $null
    $visit = {
        param([string]$n)
        if ($order -contains $n) { return }
        foreach ($r in @($byName[$n].requires)) { if ($r) { & $visit $r } }
        [void]$order.Add($n)
    }
    & $visit $Name

    $root = Join-Path $env:ProgramData 'HermesSysadmin\Modules'
    $stagingDir = Join-Path $root 'staging'
    $recordFile = Join-Path $root 'installed.json'
    $arrow = [string][char]0x2192

    $record = @{}
    if (Test-Path -LiteralPath $recordFile) {
        try {
            $json = Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $record[$p.Name] = @{ version = "$($p.Value.version)"; package_hash = "$($p.Value.package_hash)"; installed_utc = "$($p.Value.installed_utc)" } }
        } catch { $record = @{} }
    }
    $isDone = {
        param($m)
        $r = $record[$m.name]
        return ((Test-Path -LiteralPath (Join-Path $root (Join-Path $m.name $m.version))) -and $null -ne $r -and $r.version -eq "$($m.version)" -and $r.package_hash -eq "$($m.package_hash)")
    }

    if ($Preview) {
        $lines = @(foreach ($n in $order) {
            $m = $byName[$n]
            if (& $isDone $m) { "$($m.name) $($m.version): already installed" }
            else { "Download https://www.powershellgallery.com/api/v2/package/$($m.name)/$($m.version) $arrow verify SHA512 $arrow install to $(Join-Path $root (Join-Path $m.name $m.version))" }
        })
        $current = @(foreach ($n in $order) {
            $m = $byName[$n]
            @{ name = $m.name; version = $m.version; installed = [bool](Test-Path -LiteralPath (Join-Path $root (Join-Path $m.name $m.version))); verified = [bool](& $isDone $m) }
        })
        return @{
            summary = "Install $Name and its pinned dependencies ($($order.Count) module(s)) into $root"
            changes = $lines
            current = @{ root = $root; items = $current }
        }
    }

    [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

    $results = @()
    foreach ($n in $order) {
        $m = $byName[$n]
        if (& $isDone $m) { $results += @{ name = $m.name; version = $m.version; action = 'already installed' }; continue }
        $pkg = Join-Path $stagingDir "$($m.name).$($m.version).nupkg"
        $tmp = Join-Path $root (".tmp-" + [guid]::NewGuid().ToString('N'))
        try {
            if (-not (Test-Path -LiteralPath $pkg)) {
                $url = "https://www.powershellgallery.com/api/v2/package/$($m.name)/$($m.version)"
                Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $pkg
            }
            $hex = (Get-FileHash -LiteralPath $pkg -Algorithm SHA512).Hash
            $bytes = [byte[]]@($hex -split '(?<=\G..)' | Where-Object { $_ } | ForEach-Object { [Convert]::ToByte($_, 16) })
            $actual = [Convert]::ToBase64String($bytes)
            if ($actual -ne $m.package_hash) {
                Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue
                throw "$($m.name) $($m.version): package SHA512 does not match the pinned hash; the download was deleted."
            }
            [IO.Compression.ZipFile]::ExtractToDirectory($pkg, $tmp)
            foreach ($junk in @('_rels', 'package')) { Remove-Item -LiteralPath (Join-Path $tmp $junk) -Recurse -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath (Join-Path $tmp '[Content_Types].xml') -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $tmp -Filter '*.nuspec' -File | Remove-Item -Force
            if ($m.signer) {
                $files = @(Get-ChildItem -LiteralPath $tmp -Recurse -File | Where-Object { $_.Extension -in @('.psd1', '.psm1', '.ps1') })
                if ($files.Count -eq 0) { throw "$($m.name) $($m.version): no script files to verify the signature of." }
                foreach ($f in $files) {
                    $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
                    if ("$($sig.Status)" -ne 'Valid') { throw "$($m.name) $($m.version): $($f.Name) signature is $($sig.Status)." }
                    if (-not $sig.SignerCertificate -or -not $sig.SignerCertificate.Subject.Contains($m.signer)) { throw "$($m.name) $($m.version): $($f.Name) is not signed by $($m.signer)." }
                }
            }
            $dest = Join-Path $root (Join-Path $m.name $m.version)
            New-Item -ItemType Directory -Path (Join-Path $root $m.name) -Force | Out-Null
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Move-Item -LiteralPath $tmp -Destination $dest
            $record[$m.name] = @{ version = "$($m.version)"; package_hash = "$($m.package_hash)"; installed_utc = (Get-Date).ToUniversalTime().ToString('o') }
            $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordFile -Encoding UTF8
            $results += @{ name = $m.name; version = $m.version; action = 'installed'; path = $dest }
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    @{ requested = $Name; root = $root; modules = $results }
}
