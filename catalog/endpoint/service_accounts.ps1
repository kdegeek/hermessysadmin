<# hermes-catalog
id: endpoint.service_accounts
title: Services running as named accounts
category: Endpoint health
description: Services configured to log on as something other than LocalSystem, LocalService, NetworkService or a virtual NT SERVICE account - typically domain service accounts or gMSAs. Shows the account name only; stored service passwords are never read. managed is true for accounts ending in $ (gMSA or computer account).
module: inbox:CimCmdlets
target: endpoint
tier: R
columns: [host, name, display, account, managed, start_mode, state]
tags: [service account, logon as, run as, gmsa, domain account, credentials, service]
source: In-box CIM (Win32_Service StartName)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $builtin = @('localsystem', '.\localsystem', 'localservice', 'networkservice')
        Get-CimInstance Win32_Service -Property Name, DisplayName, StartName, StartMode, State | Where-Object {
            $a = "$($_.StartName)".Trim().ToLowerInvariant()
            $a -and ($builtin -notcontains $a) -and $a -notlike 'nt authority\*' -and $a -notlike 'nt service\*'
        } | Select-Object -First 500 | ForEach-Object {
            $acct = "$($_.StartName)".Trim()
            [pscustomobject]@{ name = "$($_.Name)"; display = "$($_.DisplayName)"; account = $acct; managed = $acct.EndsWith('$')
                               start_mode = "$($_.StartMode)"; state = "$($_.State)" }
        }
    }
}
