<# hermes-catalog
id: patch.office_c2r
title: Microsoft 365 Apps (Click-to-Run) version and channel
category: Patching
description: Microsoft 365 Apps / Office Click-to-Run version, update channel, installed products, platform and whether automatic updates are on, per computer, plus the channel set by Group Policy if any. installed is false when Click-to-Run Office is not present (MSI Office is not covered). The channel is named from the known Microsoft CDN IDs; anything else, such as an internal share, is shown as the raw source.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: R
columns: [host, installed, version, channel, products, platform, updates_enabled, policy_channel]
tags: [office, microsoft 365 apps, m365, click-to-run, c2r, office version, update channel, monthly enterprise, current channel, semi-annual]
source: In-box registry (HKLM Office\ClickToRun\Configuration and Policies office\16.0\common\officeupdate)
#>
param([string[]]$Computers = @(), [string]$Ou)
Invoke-Op {
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Workstation
    Invoke-HermesCatalogFanout -Computers $targets -Script {
        $ErrorActionPreference = 'Stop'
        $channels = @{
            '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
            '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
            '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
            '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
            'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
            '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
        }
        $c = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
        $pol = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate' -ErrorAction SilentlyContinue
        $policyChannel = $null
        if ($pol -and $pol.updatebranch) { $policyChannel = "$($pol.updatebranch)" }
        if (-not $c -or -not $c.VersionToReport) {
            return [pscustomobject]@{ installed = $false; version = $null; channel = $null; products = @(); platform = $null; updates_enabled = $null; policy_channel = $policyChannel }
        }
        $src = "$($c.UpdateChannel)"
        if (-not $src) { $src = "$($c.CDNBaseUrl)" }
        $channel = $src
        $m = [regex]::Match($src, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($m.Success -and $channels.ContainsKey($m.Value.ToLowerInvariant())) { $channel = $channels[$m.Value.ToLowerInvariant()] }
        if ($channel.Length -gt 200) { $channel = $channel.Substring(0, 200) }
        [pscustomobject]@{
            installed = $true
            version = "$($c.VersionToReport)"
            channel = $channel
            products = @("$($c.ProductReleaseIds)" -split ',' | Where-Object { $_ })
            platform = "$($c.Platform)"
            updates_enabled = $(if ($null -ne $c.UpdatesEnabled) { "$($c.UpdatesEnabled)" -eq 'True' } else { $null })
            policy_channel = $policyChannel
        }
    }
}
