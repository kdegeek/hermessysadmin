param([Parameter(Mandatory)][string]$ComputerName)
Invoke-Op {
    $r = Invoke-HermesOne -Computer $ComputerName -Script {
        Import-Module WindowsServerBackup -ErrorAction Stop
        $j = Get-WBJob -ErrorAction SilentlyContinue
        $current = $null
        if ($j -and "$($j.JobState)" -eq 'Running') {
            $pct = $null
            if ("$($j.CurrentOperation)" -match '(\d{1,3})\s*%') { $pct = [int]$Matches[1] }
            $current = [pscustomobject]@{ running = $true; type = "$($j.JobType)"; operation = "$($j.CurrentOperation)"; percent = $pct; started = ([datetime]$j.StartTime).ToUniversalTime().ToString('o') }
        }
        $events = @(Get-WinEvent -LogName 'Microsoft-Windows-Backup' -MaxEvents 30 -ErrorAction SilentlyContinue | ForEach-Object {
            $m = "$($_.Message)"
            [pscustomobject]@{ time = $_.TimeCreated.ToUniversalTime().ToString('o'); id = [int]$_.Id; level = "$($_.LevelDisplayName)"; message = $(if ($m.Length -gt 300) { $m.Substring(0, 300) } else { $m }) }
        })
        [pscustomobject]@{ current = $current; history = $events }
    }
    $cur = $null
    if ($r.current) { $cur = @{ running = $true; type = $r.current.type; operation = $r.current.operation; percent = $r.current.percent; started = $r.current.started } }
    @{
        host    = $ComputerName
        current = $cur
        history = @($r.history | ForEach-Object { @{ time = $_.time; id = $_.id; level = $_.level; message = $_.message } })
    }
}
