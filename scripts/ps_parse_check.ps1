param([Parameter(Mandatory)][string]$Path)
$bad = 0
Get-ChildItem -Path $Path -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $bad++
        foreach ($e in $errors) { Write-Output "$($_.Name):$($e.Extent.StartLineNumber): $($e.Message)" }
    }
}
if ($bad -gt 0) { exit 1 }
Write-Output 'All scripts parse.'
