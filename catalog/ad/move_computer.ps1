<# hermes-catalog
id: ad.move_computer
title: Move a computer to another OU
category: AD hygiene
description: Moves one computer account to another OU or container. The GPOs linked to the new OU apply at the computer's next policy refresh, so check what they do first. Refuses domain controllers, protected or critical objects and the Domain Controllers OU as a destination. Undo by moving it back to the OU shown in the result.
module: inbox:ActiveDirectory
target: dc
tier: W
preview: plan
columns: [name, from, to]
tags: [move computer, ou, organizational unit, computer account, move-adobject, reorganise, gpo scope]
source: In-box ActiveDirectory (Get-ADComputer, Move-ADObject)
params:
  - {name: Name, type: string, required: true, description: "The computer name without the trailing $, for example PC0142."}
  - {name: TargetOu, type: string, required: true, description: "Distinguished name of the destination OU or container, for example OU=Laptops,OU=Workstations,DC=corp,DC=example."}
#>
param([string]$Name, [string]$TargetOu, [switch]$Preview)
Invoke-Op {
    if ($Name -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,14}\z') { throw "InvalidArguments: Name must be a computer name of 1-15 letters, digits, '_' or '-', without the trailing `$." }
    if ($TargetOu -cnotmatch '\A(OU|CN)=[A-Za-z0-9 ._&()\\=,-]{1,1000}\z' -or $TargetOu -cnotmatch ',DC=[A-Za-z0-9-]+\z') {
        throw "InvalidArguments: TargetOu must be a distinguished name such as OU=Laptops,DC=corp,DC=example (letters, digits, space and . _ & ( ) \ = , - only)."
    }
    $found = @(Get-ADComputer -LDAPFilter "(sAMAccountName=$Name`$)" -Properties userAccountControl, primaryGroupID)
    if ($found.Count -ne 1) { throw "Cannot find a single computer named '$Name'." }
    $c = $found[0]
    Assert-HermesNotProtected $c
    if ([int]$c.userAccountControl -band 8192 -or [int]$c.userAccountControl -band 67108864) { throw "PolicyBlocked: $($c.Name) is a domain controller; the plugin will not move it." }
    $dest = Get-ADObject -Identity $TargetOu -ErrorAction Stop
    if (@('organizationalUnit', 'container') -notcontains "$($dest.ObjectClass)") { throw "InvalidArguments: $TargetOu is a $($dest.ObjectClass), not an OU or container." }
    $dcOu = "$((Get-ADDomain).DomainControllersContainer)"
    if ($dest.DistinguishedName -eq $dcOu -or $dest.DistinguishedName.EndsWith(",$dcOu", [StringComparison]::OrdinalIgnoreCase)) {
        throw "PolicyBlocked: refusing to move a computer into the Domain Controllers OU; DC policies would apply to it."
    }
    $from = Get-ParentDn $c.DistinguishedName
    if ($from -eq $dest.DistinguishedName) { throw "InvalidArguments: $($c.Name) is already in $($dest.DistinguishedName)." }
    if ($Preview) {
        return @{ summary = "Move computer $($c.Name) to $($dest.DistinguishedName)"
                  changes = @("$($c.Name): move from $from to $($dest.DistinguishedName); GPOs linked there apply at the next policy refresh")
                  current = @{ name = $c.Name; ou = $from } }
    }
    Move-ADObject -Identity $c.DistinguishedName -TargetPath $dest.DistinguishedName -ErrorAction Stop
    $now = Get-ADComputer -Identity $c.ObjectGUID
    @{ items = @(@{ name = $c.Name; from = $from; to = (Get-ParentDn $now.DistinguishedName) }); summary = @{ moved = 1 } }
}
