<# hermes-catalog
id: gpo.settings_search
title: Search GPO settings by keyword
category: Group Policy
description: Finds GPOs whose settings mention a keyword (case-insensitive, plain text, not a pattern), for example a registry key, a server name, a share path or a policy name. Reads each GPO's XML settings report and returns the GPO, side, settings area, the setting's name and a short excerpt around the match. Settings that mention a password, secret, key, token or credential are skipped entirely; they are neither matched nor returned, so no keyword can reveal anything about their values. Script parameters, command-line arguments, run-as accounts and Group Policy Preferences cpassword values are never read into the search, and a script command is only searched when it is a plain path to a script or program. Reports are generated one GPO at a time, so large domains take a while; at most MaxGpos GPOs and 20 matches per GPO are checked.
module: inbox:GroupPolicy
target: dc
tier: R
columns: [gpo, side, area, setting, excerpt]
tags: [gpo, group policy, search, find setting, which gpo sets, keyword, registry, gpo report, settings]
source: In-box GroupPolicy (Get-GPO -All, Get-GPOReport -ReportType Xml)
params:
  - {name: Keyword, type: string, required: true, description: "Text to look for: 2-64 letters, digits, spaces and the characters . _ - \\ / : { }"}
  - {name: MaxGpos, type: integer, default: 200, minimum: 1, maximum: 1000, description: Most GPOs to search (alphabetical by name).}
#>
param([string]$Keyword, [int]$MaxGpos = 200)
Invoke-Op {
    if ($Keyword -cnotmatch '\A[A-Za-z0-9 ._\\/:{}-]{2,64}\z' -or $Keyword.Trim().Length -lt 2) { throw 'InvalidArguments: Keyword must be 2-64 characters of letters, digits, spaces and . _ - \ / : { }' }
    if ($MaxGpos -lt 1) { $MaxGpos = 1 }
    if ($MaxGpos -gt 1000) { $MaxGpos = 1000 }
    $secret = '(?i)password|passwd|pwd|secret|credential|cpassword|token|api.?key|private.?key|shared.?key|psk|passphrase|(?<!by)pass(?!(through|thru|ive|port))|licen[cs]e.?key|product.?key|access.?key|conn(ection)?[ ._-]?str|sas.?sig'
    # Never indexed: arguments and parameters of scripts, tasks and shortcuts, run-as accounts and stored passwords.
    $noIndexAttr = @('cpassword', 'password', 'arguments', 'args', 'parameters', 'params', 'runas', 'commandline', 'cmdline')
    $noIndexEl = '\A(?i:Parameters|Arguments|Args|Params|CommandLine|CmdLine|RunAs|cpassword|Password)\z'
    # A script/program command is searchable only when it is a bare path (no switches, no shell syntax).
    $pathLike = '\A"?[^"&|<>^%;]+\.(?i:bat|cmd|ps1|vbs|js|wsf|exe|kix)"?\z'
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $dcName = Get-HermesDc
    $all = @(Get-GPO -All | Sort-Object DisplayName)
    $gpos = @($all | Select-Object -First $MaxGpos)
    $errs = @()
    $rows = @()
    foreach ($g in $gpos) {
        try {
            $x = [xml](Get-GPOReport -Guid $g.Id -ReportType Xml)
        } catch { $errs += @{ host = $dcName; message = "$($g.DisplayName): $($_.Exception.Message)" }; continue }
        $seen = @{}
        $hits = 0
        foreach ($sideName in @('Computer', 'User')) {
            $sideNode = @($x.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq $sideName }) | Select-Object -First 1
            if (-not $sideNode) { continue }
            foreach ($ed in @($sideNode.ChildNodes | Where-Object { $_.LocalName -eq 'ExtensionData' })) {
                $area = "$(@($ed.ChildNodes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 | ForEach-Object { $_.InnerText }))"
                $ext = @($ed.ChildNodes | Where-Object { $_.LocalName -eq 'Extension' }) | Select-Object -First 1
                if (-not $ext) { continue }
                foreach ($node in @($ext.SelectNodes('.//*'))) {
                    if ($hits -ge 20) { break }
                    # Skip anything that is, or sits inside, a parameters/arguments/run-as/password element.
                    $inside = $false
                    $up = $node
                    while ($up -and -not [object]::ReferenceEquals($up, $ext)) {
                        if ("$($up.LocalName)" -match $noIndexEl) { $inside = $true; break }
                        $up = $up.ParentNode
                    }
                    if ($inside) { continue }
                    # The element's own text: its attributes (never cpassword, arguments or run-as) and its direct text, not its children.
                    $parts = @()
                    foreach ($a in @($node.Attributes)) {
                        if ($a -and $a.LocalName -ne 'cpassword' -and $noIndexAttr -notcontains "$($a.LocalName)".ToLowerInvariant() -and $a.Prefix -ne 'xmlns' -and $a.LocalName -ne 'xmlns') { $parts += "$($a.LocalName)=$($a.Value)" }
                    }
                    foreach ($c in @($node.ChildNodes)) {
                        if ($c -and ($c.NodeType -eq 'Text' -or $c.NodeType -eq 'CDATA')) { $parts += "$($c.Value)" }
                    }
                    # Script and task commands: only a bare path is searchable; an inline command line is skipped.
                    if ("$($node.LocalName)" -match '\A(?i:Command)\z' -and @($parts).Count -gt 0) {
                        $txt = (($parts -join ' ') -replace '\s+', ' ').Trim()
                        if ($txt -and ($txt -notmatch $pathLike -or $txt -match '\s[/-]')) { continue }
                    }
                    $own = (($parts -join ' ') -replace '\s+', ' ').Trim()
                    $at = $own.IndexOf($Keyword, $cmp)
                    if ($at -lt 0) { continue }
                    # The setting this match belongs to: the nearest element (self or up to 5 ancestors) with a name.
                    $set = $null
                    $setName = ''
                    $cur = $node
                    for ($k = 0; $k -lt 6 -and $cur -and -not [object]::ReferenceEquals($cur, $ext); $k++) {
                        $nameAttr = $cur.Attributes | Where-Object { $_.LocalName -eq 'name' } | Select-Object -First 1
                        $nameEl = @($cur.ChildNodes | Where-Object { $_.LocalName -eq 'Name' }) | Select-Object -First 1
                        if ($nameAttr) { $set = $cur; $setName = "$($nameAttr.Value)"; break }
                        if ($nameEl) { $set = $cur; $setName = "$($nameEl.InnerText)"; break }
                        $cur = $cur.ParentNode
                    }
                    if (-not $set) { $set = $node.ParentNode }
                    # A setting that mentions a credential is skipped whole: no row, no excerpt, so it cannot be probed.
                    if ((("$($set.OuterXml)" -replace 'cpassword="[^"]*"', '') -match $secret) -or $own -match $secret -or $setName -match $secret) { continue }
                    if ($setName.Length -gt 200) { $setName = $setName.Substring(0, 200) }
                    $start = [math]::Max(0, $at - 80)
                    $len = [math]::Min($own.Length - $start, 200)
                    $excerpt = $own.Substring($start, $len)
                    $key = "$sideName|$area|$setName|$excerpt"
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $hits++
                    $rows += @{ gpo = $g.DisplayName; side = $sideName; area = $area; setting = $setName; excerpt = $excerpt }
                }
            }
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; keyword = $Keyword; gpos_searched = $gpos.Count; gpos_total = $all.Count; gpos_matched = @($rows | ForEach-Object { $_.gpo } | Sort-Object -Unique).Count; truncated = (($rows.Count -gt 500) -or ($all.Count -gt $gpos.Count)) } }
}
