<# hermes-catalog
id: ad.password_policies
title: Password policies
category: AD hygiene
description: The default domain password policy plus every fine-grained password policy (PSO), with precedence, minimum length, maximum age, lockout threshold and complexity.
module: inbox:ActiveDirectory
target: dc
tier: R
columns: [name, precedence, min_length, max_age_days, lockout_threshold, complexity]
tags: [password policy, pso, fine grained, lockout, complexity, minimum length, password age]
source: In-box ActiveDirectory (Get-ADDefaultDomainPasswordPolicy, Get-ADFineGrainedPasswordPolicy)
#>
param()
Invoke-Op {
    $d = Get-ADDefaultDomainPasswordPolicy
    $rows = @(@{ name = 'Default domain policy'; precedence = $null; min_length = [int]$d.MinPasswordLength; max_age_days = [int]$d.MaxPasswordAge.TotalDays
                 lockout_threshold = [int]$d.LockoutThreshold; complexity = [bool]$d.ComplexityEnabled })
    $rows += @(Get-ADFineGrainedPasswordPolicy -Filter * | Sort-Object Precedence | ForEach-Object {
        @{ name = $_.Name; precedence = [int]$_.Precedence; min_length = [int]$_.MinPasswordLength; max_age_days = [int]$_.MaxPasswordAge.TotalDays
           lockout_threshold = [int]$_.LockoutThreshold; complexity = [bool]$_.ComplexityEnabled } })
    @{ items = @($rows | Select-Object -First 500); summary = @{ total = $rows.Count; truncated = ($rows.Count -gt 500) } }
}
