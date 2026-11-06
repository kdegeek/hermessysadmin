param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [bool]$Enforced = $false,
    [bool]$Enabled = $true,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $enabledArg = if ($Enabled) { 'Yes' } else { 'No' }
    $enforcedArg = if ($Enforced) { 'Yes' } else { 'No' }
    if ($Preview) {
        $inherit = Get-GPInheritance -Target $Target
        return @{
            summary = "Link '$($gpo.DisplayName)' to $Target"
            changes = @("New-GPLink -Guid $($gpo.Id) -Target '$Target' -LinkEnabled $enabledArg -Enforced $enforcedArg")
            current = @{
                linked_here = @($inherit.GpoLinks | ForEach-Object { $_.DisplayName })
                inherited   = @($inherit.InheritedGpoLinks | Select-Object -First 20 | ForEach-Object { $_.DisplayName })
            }
        }
    }
    $link = New-GPLink -Guid $gpo.Id -Target $Target -LinkEnabled $enabledArg -Enforced $enforcedArg
    @{ gpo = $gpo.DisplayName; target = $Target; enabled = $Enabled; enforced = $Enforced; order = $link.Order }
}
