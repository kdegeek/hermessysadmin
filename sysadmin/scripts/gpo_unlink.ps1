param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][string]$Target,
    [switch]$Preview
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    if ($Preview) {
        $inherit = Get-GPInheritance -Target $Target
        return @{
            summary = "Unlink '$($gpo.DisplayName)' from $Target"
            changes = @("Remove-GPLink -Guid $($gpo.Id) -Target '$Target'")
            current = @{ linked_here = @($inherit.GpoLinks | ForEach-Object { $_.DisplayName }) }
        }
    }
    Remove-GPLink -Guid $gpo.Id -Target $Target | Out-Null
    @{ gpo = $gpo.DisplayName; target = $Target; unlinked = $true }
}
