param(
    [Parameter(Mandatory)][string]$Identity,
    [Parameter(Mandatory)][ValidateSet('AllSettingsEnabled', 'AllSettingsDisabled', 'UserSettingsDisabled', 'ComputerSettingsDisabled')][string]$Status
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    $before = "$($gpo.GpoStatus)"
    $gpo.GpoStatus = $Status
    @{ gpo = $gpo.DisplayName; from = $before; to = $Status }
}
