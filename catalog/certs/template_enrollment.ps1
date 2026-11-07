<# hermes-catalog
id: certs.template_enrollment
title: Certificate template enrollment rights
category: Certificates
description: Who can enroll in, autoenroll in, or modify each certificate template (Enroll, AutoEnroll, FullControl, WriteDacl, WriteOwner, WriteProperty from the template's DACL). broad is true for Everyone, Authenticated Users, Users, Domain Users, Domain Computers, Domain Guests and Anonymous. esc1 repeats certs.adcs_templates' risky test (enrollee supplies subject, authentication EKU, no approval); a published esc1 template with a broad Enroll right, or any broad write right, is a privilege-escalation path. Built-in admin principals are hidden unless IncludeAdmins is set.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [template, principal, rights, broad, esc1, published]
tags: [adcs, certificate templates, enroll, autoenroll, permissions, esc1, esc4, pki, acl, template permissions]
source: In-box ActiveDirectory (Get-ADObject nTSecurityDescriptor on the Certificate Templates and Enrollment Services containers)
params:
  - {name: IncludeAdmins, type: boolean, default: false, description: Also list rights held by SYSTEM, Administrators, Domain Admins, Enterprise Admins and Enterprise Domain Controllers.}
#>
param([bool]$IncludeAdmins = $false)
Invoke-Op {
    $cfg = (Get-ADRootDSE).configurationNamingContext
    $pks = "CN=Public Key Services,CN=Services,$cfg"
    $published = @{}
    foreach ($ca in @(Get-ADObject -SearchBase "CN=Enrollment Services,$pks" -SearchScope OneLevel -LDAPFilter '(objectClass=pKIEnrollmentService)' -Properties certificateTemplates)) {
        foreach ($t in @($ca.certificateTemplates)) { $published["$t".ToLowerInvariant()] = $true }
    }
    $enrollGuid = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
    $autoGuid = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
    $authEku = @('1.3.6.1.5.5.7.3.2', '1.3.6.1.4.1.311.20.2.2', '1.3.6.1.5.2.3.4', '2.5.29.37.0')
    $adminSid = '^(S-1-5-18|S-1-5-32-544|S-1-5-9|S-1-5-21-[\d-]+-(512|519|516|498))$'
    $broadSid = '^(S-1-1-0|S-1-5-11|S-1-5-7|S-1-5-32-545|S-1-5-21-[\d-]+-(513|514|515))$'
    $props = @('nTSecurityDescriptor', 'msPKI-Enrollment-Flag', 'msPKI-Certificate-Name-Flag', 'msPKI-RA-Signature', 'pKIExtendedKeyUsage')
    $rows = @()
    foreach ($t in @(Get-ADObject -SearchBase "CN=Certificate Templates,$pks" -SearchScope OneLevel -LDAPFilter '(objectClass=pKICertificateTemplate)' -Properties $props | Sort-Object Name)) {
        $eku = @($t.pKIExtendedKeyUsage | ForEach-Object { "$_" })
        $supplies = (([int]$t.'msPKI-Certificate-Name-Flag' -band 1) -ne 0)
        $approval = ((([int]$t.'msPKI-Enrollment-Flag' -band 2) -ne 0) -or [int]$t.'msPKI-RA-Signature' -gt 0)
        $auth = ($eku.Count -eq 0) -or (@($eku | Where-Object { $authEku -contains $_ }).Count -gt 0)
        $esc1 = [bool]($supplies -and $auth -and -not $approval)
        $perSid = @{}
        foreach ($ace in @($t.nTSecurityDescriptor.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
            $sid = "$($ace.IdentityReference.Value)"
            if (-not $IncludeAdmins -and $sid -match $adminSid) { continue }
            $r = $ace.ActiveDirectoryRights
            $got = @()
            if (($r -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) -eq [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) {
                $got += 'FullControl'
            } else {
                if (($r -band [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl) -ne 0) { $got += 'WriteDacl' }
                if (($r -band [System.DirectoryServices.ActiveDirectoryRights]::WriteOwner) -ne 0) { $got += 'WriteOwner' }
                if (($r -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty) -ne 0 -and $ace.ObjectType -eq [guid]::Empty) { $got += 'WriteProperty' }
                if (($r -band [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight) -ne 0) {
                    if ($ace.ObjectType -eq $enrollGuid -or $ace.ObjectType -eq [guid]::Empty) { $got += 'Enroll' }
                    if ($ace.ObjectType -eq $autoGuid -or $ace.ObjectType -eq [guid]::Empty) { $got += 'AutoEnroll' }
                }
            }
            if ($got.Count -eq 0) { continue }
            if (-not $perSid.ContainsKey($sid)) { $perSid[$sid] = @() }
            $perSid[$sid] += $got
        }
        foreach ($sid in @($perSid.Keys | Sort-Object)) {
            $name = $sid
            try { $name = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { $name = $sid }
            $rows += @{
                template = "$($t.Name)"; principal = $name; rights = (@($perSid[$sid] | Sort-Object -Unique) -join ', ')
                broad = ($sid -match $broadSid); esc1 = $esc1; published = $published.ContainsKey("$($t.Name)".ToLowerInvariant())
            }
        }
    }
    $findings = @($rows | Where-Object { $_.broad -and $_.published -and (($_.esc1 -and $_.rights -match 'Enroll|FullControl') -or $_.rights -match 'FullControl|WriteDacl|WriteOwner|WriteProperty') }).Count
    @{ items = @($rows | Select-Object -First 500); errors = @(); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500); findings = $findings } }
}
