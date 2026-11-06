<# hermes-catalog
id: remote.send_message
title: Send a message to logged-on users
category: Users & sessions
description: Shows a pop-up message to every session on each computer using msg.exe. The message is at most 255 characters on one line.
module: inbox:Microsoft.PowerShell.Management
target: endpoint
tier: W
preview: plan
columns: [host, sent]
tags: [message, msg, notify, sessions]
source: In-box msg.exe
params:
  - {name: Message, type: string, required: true, description: Text to show. At most 255 characters and no line breaks.}
  - {name: Seconds, type: integer, default: 60, minimum: 5, description: How long the message stays on screen.}
#>
param([string[]]$Computers = @(), [string]$Ou, [string]$Message, [int]$Seconds = 60, [switch]$Preview)
Invoke-Op {
    if ([string]::IsNullOrWhiteSpace($Message)) { throw 'Message is required.' }
    if ($Message.Length -gt 255) { throw 'Message must be 255 characters or fewer.' }
    if ($Message -match '[\r\n]') { throw 'Message must not contain line breaks.' }
    $text = $Message.Replace('"', "'")
    $targets = Get-HermesTargets -Computers $Computers -Ou $Ou -Kind Any
    if ($Preview) {
        return @{ summary = "Send a message to all sessions on $($targets.Count) computer(s) for $Seconds seconds"
                  changes = @($targets | ForEach-Object { "${_}: show '$text' for $Seconds seconds" })
                  current = @{} }
    }
    Invoke-HermesCatalogFanout -Computers $targets -ArgumentList @($text, $Seconds) -Script {
        param($msg, $sec)
        & msg.exe '*' "/TIME:$sec" $msg
        [pscustomobject]@{ sent = ($LASTEXITCODE -eq 0) }
    }
}
