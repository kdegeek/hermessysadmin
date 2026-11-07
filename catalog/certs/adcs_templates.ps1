<# hermes-catalog
id: certs.adcs_templates
title: AD CS certificate template audit
category: Certificates
description: Certificate templates published in Active Directory with schema version, enrollment flags, RA signatures and EKUs. A template is flagged risky when the enrollee supplies the subject, it allows client authentication (or any purpose) and it needs no manager approval or RA signature. Read-only.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, display, schema, enroll_flags, ra_signatures, eku, risky]
tags: [adcs, pki, certificate templates, esc1, enrollee supplies subject, client authentication, ca]
source: In-box ActiveDirectory (Get-ADObject on the Certificate Templates container of the configuration partition)
#>
param()
Invoke-Op {
    $errs = @()
    $cfg = (Get-ADRootDSE).configurationNamingContext
    $base = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$cfg"
    $props = @('displayName', 'msPKI-Template-Schema-Version', 'msPKI-Enrollment-Flag', 'msPKI-Certificate-Name-Flag', 'msPKI-RA-Signature', 'pKIExtendedKeyUsage')
    $authEku = @('1.3.6.1.5.5.7.3.2', '1.3.6.1.4.1.311.20.2.2', '1.3.6.1.5.2.3.4', '2.5.29.37.0')
    $rows = @()
    foreach ($t in @(Get-ADObject -SearchBase $base -SearchScope OneLevel -LDAPFilter '(objectClass=pKICertificateTemplate)' -Properties $props | Sort-Object Name)) {
        $enroll = [int]$t.'msPKI-Enrollment-Flag'
        $nameFlag = [int]$t.'msPKI-Certificate-Name-Flag'
        $ra = [int]$t.'msPKI-RA-Signature'
        $eku = @($t.pKIExtendedKeyUsage | ForEach-Object { "$_" })
        $suppliesSubject = (($nameFlag -band 1) -ne 0)
        $needsApproval = ((($enroll -band 2) -ne 0) -or $ra -gt 0)
        $authCapable = ($eku.Count -eq 0) -or (@($eku | Where-Object { $authEku -contains $_ }).Count -gt 0)
        $rows += @{
            name = "$($t.Name)"; display = "$($t.displayName)"; schema = [int]$t.'msPKI-Template-Schema-Version'
            enroll_flags = $enroll; ra_signatures = $ra; eku = ($eku -join ', ')
            risky = [bool]($suppliesSubject -and $authCapable -and -not $needsApproval)
        }
    }
    @{ items = @($rows | Select-Object -First 500); errors = $errs; summary = @{ total = $rows.Count; risky = @($rows | Where-Object { $_.risky }).Count; truncated = ($rows.Count -gt 500) } }
}
