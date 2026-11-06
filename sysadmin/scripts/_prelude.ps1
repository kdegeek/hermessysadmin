# hermes-sysadmin session prelude.
# Runs ONCE per runspace pool, in global scope, right after the pool opens.
# Defines the helpers every op script uses. Never echoes $Pass.
param(
    [Parameter(Mandatory)][string]$User,
    [Parameter(Mandatory)][string]$Pass
)
$ErrorActionPreference = 'Stop'

# Explicit credential for second-hop work (Invoke-Command to member servers).
# NTLM cannot delegate the WinRM logon, so fan-out must pass credentials explicitly.
$Global:HermesCred = New-Object System.Management.Automation.PSCredential -ArgumentList $User, (ConvertTo-SecureString -String $Pass -AsPlainText -Force)
$Global:PSDefaultParameterValues['Invoke-Command:Credential'] = $Global:HermesCred
# AD cmdlets that talk to another DC (-Server / -Target) also need explicit credentials.
$Global:PSDefaultParameterValues['*-AD*:Credential'] = $Global:HermesCred

foreach ($m in 'ActiveDirectory', 'GroupPolicy') {
    if (Get-Module -ListAvailable -Name $m) { Import-Module $m -ErrorAction SilentlyContinue }
}

# GroupPolicy cmdlets have no -Credential. Pin them to THIS domain controller so AD and
# SYSVOL access stays local (loopback) and never needs a second hop.
$Global:HermesIsDc = ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4)
if ($Global:HermesIsDc) {
    $Global:HermesLocalDc = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $Global:PSDefaultParameterValues['*-GP*:Server'] = $Global:HermesLocalDc
}

function Global:Get-CnName {
    # 'CN=Bob Smith,OU=Staff,DC=corp' -> 'Bob Smith'
    param([string]$Dn)
    if (-not $Dn) { return $null }
    return ((($Dn -split '(?<!\\),')[0]) -replace '^(CN|OU|DC)=', '') -replace '\\,', ','
}

function Global:Get-ParentDn {
    param([string]$Dn)
    if (-not $Dn) { return $null }
    $parts = $Dn -split '(?<!\\),', 2
    if ($parts.Count -gt 1) { return $parts[1] }
    return $null
}

function Global:New-HermesPassword {
    # Cryptographically random password guaranteed to contain upper, lower, digit and symbol.
    param([int]$Length = 20)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+=?@-')
    $all = -join $sets
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $chars = @(foreach ($b in $bytes) { $all[$b % $all.Length] })
    $shuffle = New-Object byte[] $sets.Count
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($shuffle)
    for ($i = 0; $i -lt $sets.Count; $i++) {
        $pos = $shuffle[$i] % $Length
        $chars[$pos] = $sets[$i][$bytes[$pos] % $sets[$i].Length]
    }
    return (-join $chars)
}

function Global:ConvertTo-HermesSecure {
    param([Parameter(Mandatory)][string]$Plain)
    return (ConvertTo-SecureString -String $Plain -AsPlainText -Force)
}

function Global:ConvertTo-LdapValue {
    # Escape a value for use inside an LDAP filter (RFC 4515).
    param([string]$Value)
    return ($Value -replace '\\', '\5c' -replace '\*', '\2a' -replace '\(', '\28' -replace '\)', '\29' -replace "`0", '\00')
}

function Global:Get-HermesGpo {
    # Resolve a GPO by GUID (with or without braces) or by display name.
    param([Parameter(Mandatory)][string]$Identity)
    if ($Identity -match '^\{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}?$') { return Get-GPO -Guid $Identity.Trim('{}') }
    return Get-GPO -Name $Identity
}

function Global:Get-XmlText {
    # Text of an XML node whether PowerShell surfaced it as a string or an XmlNode (CDATA).
    param($Node)
    if ($null -eq $Node) { return '' }
    if ($Node -is [System.Xml.XmlNode]) { return $Node.InnerText }
    return "$Node"
}

function Global:Assert-Hermes {
    # Script-side validation that maps to InvalidArguments.
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { Write-Error -Message $Message -Category InvalidArgument -ErrorAction Stop }
}

function Global:Iso {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    try { return ([datetime]$Value).ToUniversalTime().ToString('o') } catch { return "$Value" }
}

function Global:Get-HermesErrorType {
    param($Err)
    $name = $Err.Exception.GetType().Name
    $cat = "$($Err.CategoryInfo.Category)"
    $msg = "$($Err.Exception.Message)"
    if ($name -match 'IdentityNotFound|NotFound' -or $cat -eq 'ObjectNotFound' -or $msg -match 'Cannot find an object|was not found|does not exist') { return 'NotFound' }
    if ($name -match 'UnauthorizedAccess' -or $cat -in @('PermissionDenied', 'SecurityError') -or $msg -match 'Access is denied|Insufficient access rights') { return 'PermissionDenied' }
    if ($cat -in @('InvalidArgument', 'InvalidData')) { return 'InvalidArguments' }
    if ($msg -match 'timed out|timeout') { return 'Timeout' }
    return 'RemoteScriptError'
}

function Global:Invoke-Op {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $ErrorActionPreference = 'Stop'
    try {
        $data = & $Body
        return (ConvertTo-Json -InputObject @{ ok = $true; data = $data } -Depth 10 -Compress)
    } catch {
        $e = $_
        $err = @{
            type     = (Get-HermesErrorType $e)
            message  = "$($e.Exception.Message)"
            category = "$($e.CategoryInfo.Category)"
            target   = "$($e.TargetObject)"
        }
        return (ConvertTo-Json -InputObject @{ ok = $false; error = $err } -Depth 5 -Compress)
    }
}

function Global:Get-HermesFanout {
    # Runs $Script on each computer with the explicit credential.
    # The remote scriptblock MUST emit [pscustomobject]@{...} values.
    param(
        [Parameter(Mandatory)][string[]]$Computers,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    $errs = $null
    $raw = Invoke-Command -ComputerName $Computers -ScriptBlock $Script -ArgumentList $ArgumentList -ThrottleLimit 16 -ErrorAction SilentlyContinue -ErrorVariable errs
    $results = @(foreach ($r in $raw) {
        $h = @{}
        foreach ($p in $r.PSObject.Properties) {
            if ($p.Name -notin @('PSComputerName', 'RunspaceId', 'PSShowComputerName')) { $h[$p.Name] = $p.Value }
        }
        $h['host'] = "$($r.PSComputerName)"
        $h
    })
    $failed = @(foreach ($e in @($errs)) {
        $hostName = if ($e.OriginInfo -and $e.OriginInfo.PSComputerName) { "$($e.OriginInfo.PSComputerName)" } else { "$($e.TargetObject)" }
        @{ host = $hostName; message = "$($e.Exception.Message)" }
    })
    return @{ results = $results; errors = $failed }
}
