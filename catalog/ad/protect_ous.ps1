<# hermes-catalog
id: ad.protect_ous
title: Protect OUs from accidental deletion
category: AD hygiene
description: Turns on "protect from accidental deletion" for the listed OUs, or for every unprotected OU when All is true. It only ever turns protection on; OUs already protected are left alone. Up to 200 OUs per run. Undo by clearing the checkbox on the OU's Object tab.
module: inbox:ActiveDirectory
target: dc
tier: W
preview: plan
columns: [ou, before, after]
tags: [ou, accidental deletion, protect, organizational units, protectedfromaccidentaldeletion, hardening, hygiene]
source: In-box ActiveDirectory (Get-ADOrganizationalUnit, Set-ADOrganizationalUnit -ProtectedFromAccidentalDeletion)
params:
  - {name: OrganizationalUnits, type: array, description: "Distinguished names of the OUs to protect, for example OU=Staff,DC=corp,DC=example."}
  - {name: All, type: boolean, default: false, description: Protect every OU in the domain that is not yet protected.}
#>
param([string[]]$OrganizationalUnits = @(), [bool]$All = $false, [switch]$Preview)
Invoke-Op {
    $list = @($OrganizationalUnits | Where-Object { $_ })
    if (-not $All -and $list.Count -eq 0) { throw 'InvalidArguments: give OrganizationalUnits or set All to true.' }
    if ($All -and $list.Count -gt 0) { throw 'InvalidArguments: give OrganizationalUnits or All, not both.' }
    foreach ($dn in $list) {
        if ($dn -cnotmatch '\AOU=[A-Za-z0-9 ._&()\\=,-]{1,1000}\z' -or $dn -cnotmatch ',DC=[A-Za-z0-9-]+\z') {
            throw "InvalidArguments: '$dn' must be an OU distinguished name such as OU=Staff,DC=corp,DC=example (letters, digits, space and . _ & ( ) \ = , - only)."
        }
    }
    if ($All) {
        $ous = @(Get-ADOrganizationalUnit -Filter * -Properties ProtectedFromAccidentalDeletion)
    } else {
        $ous = @(foreach ($dn in ($list | Sort-Object -Unique)) { Get-ADOrganizationalUnit -Identity $dn -Properties ProtectedFromAccidentalDeletion -ErrorAction Stop })
    }
    $todo = @($ous | Where-Object { -not $_.ProtectedFromAccidentalDeletion })
    if ($todo.Count -gt 200) { throw "InvalidArguments: $($todo.Count) OUs need protection; at most 200 are changed per run. Pass an explicit list." }
    if ($Preview) {
        $cur = @{}
        foreach ($o in $ous) { $cur[$o.DistinguishedName] = [bool]$o.ProtectedFromAccidentalDeletion }
        return @{ summary = "Protect $($todo.Count) OU(s) from accidental deletion ($($ous.Count - $todo.Count) already protected)"
                  changes = @($todo | ForEach-Object { "$($_.DistinguishedName): protected False -> True" })
                  current = $cur }
    }
    $rows = @(foreach ($o in $todo) {
        Set-ADOrganizationalUnit -Identity $o.DistinguishedName -ProtectedFromAccidentalDeletion $true -ErrorAction Stop
        $after = (Get-ADOrganizationalUnit -Identity $o.DistinguishedName -Properties ProtectedFromAccidentalDeletion).ProtectedFromAccidentalDeletion
        @{ ou = $o.DistinguishedName; before = $false; after = [bool]$after }
    })
    @{ items = $rows; summary = @{ changed = $rows.Count; already_protected = ($ous.Count - $todo.Count); truncated = $false } }
}
