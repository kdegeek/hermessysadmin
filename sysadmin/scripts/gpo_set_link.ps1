param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [Nullable[bool]]$Enforced = $null,
    [Nullable[bool]]$Enabled = $null,
    [switch]$Preview
)
Invoke-Op {
    Assert-Hermes ($null -ne $Enforced -or $null -ne $Enabled) 'Give enforced and/or enabled.'
    $gpo = Get-HermesGpo $Identity
    $splat = @{ Guid = $gpo.Id; Target = $Target }
    if ($null -ne $Enforced) { $splat.Enforced = $(if ($Enforced) { 'Yes' } else { 'No' }) }
    if ($null -ne $Enabled) { $splat.LinkEnabled = $(if ($Enabled) { 'Yes' } else { 'No' }) }
    if ($Preview) {
        $parts = @($splat.Keys | Where-Object { $_ -notin 'Guid', 'Target' } | ForEach-Object { "-$_ $($splat[$_])" })
        return @{ summary = "Change link of '$($gpo.DisplayName)' on $Target"; changes = @("Set-GPLink -Guid $($gpo.Id) -Target '$Target' $($parts -join ' ')") }
    }
    $link = Set-GPLink @splat
    @{ gpo = $gpo.DisplayName; target = $Target; enabled = "$($link.Enabled)"; enforced = "$($link.Enforced)"; order = $link.Order }
}
