param([string]$Identity)
Invoke-Op {
    $filterId = $null
    if ($Identity) { $filterId = (Get-HermesGpo $Identity).Id.ToString() }
    $dc = Get-HermesDc
    # The backup folder is on the DC; read it there (inline over WinRM on a DC, one hop otherwise).
    $r = Invoke-HermesOnDc -ArgumentList @($filterId) -Script {
        param($FilterId)
        $ErrorActionPreference = 'Stop'
        $root = Join-Path $env:ProgramData 'HermesSysadmin\GpoBackups'
        $text = { param($Node) if ($null -eq $Node) { '' } elseif ($Node -is [System.Xml.XmlNode]) { $Node.InnerText } else { "$Node" } }
        $utc = { param($Value) try { ([datetime]$Value).ToUniversalTime().ToString('o') } catch { "$Value" } }
        $found = @()
        if (Test-Path -LiteralPath $root) {
            $found = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
                $info = Join-Path $_.FullName 'bkupInfo.xml'
                if (-not (Test-Path -LiteralPath $info)) { return }
                [xml]$x = Get-Content -LiteralPath $info -Raw
                $gid = (& $text $x.BackupInst.GPOGuid).Trim('{}')
                if ($FilterId -and $gid -ne $FilterId) { return }
                [pscustomobject]@{
                    backup_id = (& $text $x.BackupInst.ID).Trim('{}')
                    gpo_id    = $gid
                    gpo       = (& $text $x.BackupInst.GPODisplayName)
                    time      = (& $utc (& $text $x.BackupInst.BackupTime))
                    comment   = (& $text $x.BackupInst.Comment)
                }
            })
        }
        [pscustomobject]@{ root = $root; items = $found }
    }
    $items = @(@($r.items) | Where-Object { $_ } | ForEach-Object {
        @{ backup_id = "$($_.backup_id)"; gpo_id = "$($_.gpo_id)"; gpo = "$($_.gpo)"; time = "$($_.time)"; comment = "$($_.comment)" }
    } | Sort-Object { $_.time } -Descending)
    @{ items = $items; path = "$($r.root)"; dc = $dc }
}
