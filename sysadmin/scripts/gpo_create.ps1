param(
    [Parameter(Mandatory)][string]$Name,
    [string]$Comment
)
Invoke-Op {
    $splat = @{ Name = $Name }
    if ($Comment) { $splat.Comment = $Comment }
    $gpo = New-GPO @splat
    @{ id = $gpo.Id.ToString(); name = $gpo.DisplayName; status = "$($gpo.GpoStatus)" }
}
