param(
    [Parameter(Mandatory)][string]$Identity,
    [ValidateSet('summary', 'html')][string]$Format = 'summary'
)
Invoke-Op {
    $gpo = Get-HermesGpo $Identity
    if ($Format -eq 'html') {
        return @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; html = (Get-GPOReport -Guid $gpo.Id -ReportType Html) }
    }
    [xml]$x = Get-GPOReport -Guid $gpo.Id -ReportType Xml
    $sections = @()
    foreach ($scope in @('Computer', 'User')) {
        $node = $x.GPO.$scope
        if (-not $node) { continue }
        foreach ($ext in @($node.ExtensionData)) {
            if (-not $ext -or -not $ext.Extension) { continue }
            $settings = @()
            foreach ($p in @($ext.Extension.SelectNodes(".//*[local-name()='Policy']"))) {
                $value = "$($p.Numeric.Value)$($p.EditText.Value)$($p.DropDownList.Value.Name)$($p.CheckBox.State)"
                $settings += @{ name = "$($p.Name)"; state = "$($p.State)"; category = "$($p.Category)"; value = $value }
            }
            foreach ($r in @($ext.Extension.SelectNodes(".//*[local-name()='RegistrySetting']"))) {
                $settings += @{ name = "$($r.KeyPath)\$($r.Value.Name)"; state = 'Set'; category = 'Registry'; value = "$($r.Value.Number)$($r.Value.String)" }
            }
            foreach ($s in @($ext.Extension.SelectNodes(".//*[local-name()='SecurityOptions' or local-name()='Account' or local-name()='Audit' or local-name()='UserRightsAssignment']"))) {
                $name = "$($s.KeyName)$($s.Name)$($s.SystemAccessPolicyName)"
                $value = "$($s.SettingNumber)$($s.SettingString)$($s.SettingBoolean)$($s.Display.DisplayString)"
                $settings += @{ name = $name; state = 'Set'; category = "$($s.LocalName)"; value = $value }
            }
            $sections += @{ scope = $scope; extension = "$($ext.Name)"; settings = @($settings | Select-Object -First 200) }
        }
    }
    @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; sections = $sections }
}
