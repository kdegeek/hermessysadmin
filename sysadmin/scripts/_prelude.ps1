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
# Do not leave the plaintext password/user lingering in the runspace's global scope.
Remove-Variable -Name Pass, User -ErrorAction SilentlyContinue

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
    if ($Length -lt 4) { throw 'New-HermesPassword: Length must be at least 4.' }
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+=?@-')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        # Uniform random int in [0, $max) by rejection sampling.
        $next = {
            param([int]$max)
            $buf = New-Object byte[] 4
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$max)
            do { $rng.GetBytes($buf); $v = [BitConverter]::ToUInt32($buf, 0) } while ($v -ge $limit)
            return [int]($v % [uint32]$max)
        }
        $chars = New-Object char[] $Length
        for ($i = 0; $i -lt $Length; $i++) { $chars[$i] = $all[(& $next $all.Length)] }
        # Partial Fisher-Yates: 4 DISTINCT positions, one forced per character class.
        $idx = 0..($Length - 1)
        for ($i = 0; $i -lt 4; $i++) {
            $j = $i + (& $next ($Length - $i))
            $t = $idx[$i]; $idx[$i] = $idx[$j]; $idx[$j] = $t
            $set = $sets[$i]
            $chars[$idx[$i]] = $set[(& $next $set.Length)]
        }
        return (-join $chars)
    } finally {
        $rng.Dispose()
    }
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

function Global:Resolve-HermesMember {
    # Resolve a group-member identity to exactly ONE object, the same way the membership cmdlets
    # will (DN, GUID, SID, sAMAccountName or UPN; never a display name), so the object checked is
    # the object changed.
    param([Parameter(Mandatory)][string]$Identity)
    $id = $Identity.Trim()
    $props = @('objectSid', 'primaryGroupID', 'isCriticalSystemObject', 'objectClass')
    if ($id -match '^\{?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}?$' -or $id -match '^(CN|OU|DC)\s*=') {
        $found = @(Get-ADObject -Identity $id -Properties $props)
    } elseif ($id -match '^S-1-') {
        $found = @(Get-ADObject -Filter 'objectSid -eq $id' -Properties $props)
    } else {
        $v = ConvertTo-LdapValue $id
        $found = @(Get-ADObject -LDAPFilter "(|(sAMAccountName=$v)(userPrincipalName=$v))" -Properties $props)
    }
    if ($found.Count -eq 0) { throw "Cannot find an object with identity '$Identity'." }
    if ($found.Count -gt 1) { throw "Identity '$Identity' matches $($found.Count) objects; use a DN or sAMAccountName." }
    $found[0]
}

function Global:Assert-HermesNotProtected {
    # Refuse to touch built-in/critical AD objects, judged on the RESOLVED object (not its name).
    # -AsMember: the object is only being added to / removed from a group, so built-in GROUPS
    # (critical system objects such as Domain Users) may be nested; protected accounts and DCs may not.
    param([Parameter(Mandatory)]$Object, [switch]$AsMember)
    $o = Get-ADObject -Identity $Object.DistinguishedName -Properties objectSid, primaryGroupID, isCriticalSystemObject, objectClass
    $sid = "$($o.objectSid)"
    $pgid = 0
    if ($null -ne $o.primaryGroupID) { $pgid = [int]$o.primaryGroupID }
    $reason = $null
    if ($sid -match '-(500|502)$') { $reason = 'a built-in protected account (RID 500/502)' }
    elseif ($pgid -eq 516 -or $pgid -eq 521) { $reason = 'a domain controller computer account' }
    elseif ($o.isCriticalSystemObject -eq $true -and -not ($AsMember -and "$($o.objectClass)" -eq 'group')) { $reason = 'a critical system object' }
    if ($reason) { throw "PolicyBlocked: $($o.DistinguishedName) is $reason; the plugin will not modify it." }
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
    if ($msg -match '^PolicyBlocked:') { return 'PolicyBlocked' }
    if ($msg -match '^NotInstalled:') { return 'NotInstalled' }
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

function Global:Get-HermesTargets {
    param(
        [string[]]$Computers = @(),
        [string]$Ou,
        [string]$SearchBase,
        [ValidateSet('Server','Workstation','Any')][string]$Kind = 'Server'
    )
    $t = @($Computers | Where-Object { $_ })
    if ($Ou) {
        $t += @(Get-ADComputer -Filter "Enabled -eq 'True'" -SearchBase $Ou -Properties DNSHostName | ForEach-Object { $_.DNSHostName } | Where-Object { $_ })
    }
    # Fall back to every domain server ONLY when neither -Computers nor -Ou was supplied;
    # a supplied OU that yields nothing stays an empty list.
    if ($t.Count -eq 0 -and -not $Ou -and @($Computers | Where-Object { $_ }).Count -eq 0) {
        $filter = switch ($Kind) {
            'Server'      { "OperatingSystem -like '*Server*' -and Enabled -eq 'True'" }
            'Workstation' { "OperatingSystem -notlike '*Server*' -and Enabled -eq 'True'" }
            default       { "Enabled -eq 'True'" }
        }
        $splat = @{ Filter = $filter; Properties = 'DNSHostName' }
        if ($SearchBase -and $Kind -eq 'Server') { $splat.SearchBase = $SearchBase }
        $t = @(Get-ADComputer @splat | ForEach-Object { $_.DNSHostName } | Where-Object { $_ })
    }
    return @($t | Sort-Object -Unique | Select-Object -First 200)
}

function Global:Invoke-HermesOne {
    param(
        [Parameter(Mandatory)][string]$Computer,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    $r = Get-HermesFanout -Computers @($Computer) -Script $Script -ArgumentList $ArgumentList
    if ($r.errors.Count -gt 0) { throw "$($r.errors[0].host): $($r.errors[0].message)" }
    if ($r.results.Count -eq 0) { throw "$Computer returned no result." }
    return $r.results[0]
}

function Global:Invoke-HermesCatalogFanout {
    # Runs $Script on each computer; every object a host emits becomes one row with 'host' added.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Computers,
        [Parameter(Mandatory)][scriptblock]$Script,
        [object[]]$ArgumentList = @()
    )
    if ($Computers.Count -eq 0) { return @{ items = @(); errors = @(); summary = @{ hosts = 0; ok = 0; failed = 0 } } }
    $opt = New-PSSessionOption -OpenTimeout 5000 -OperationTimeout 60000
    $errs = $null
    $raw = Invoke-Command -ComputerName $Computers -ScriptBlock $Script -ArgumentList $ArgumentList -SessionOption $opt -ThrottleLimit 16 -ErrorAction SilentlyContinue -ErrorVariable errs
    $items = @(foreach ($r in @($raw)) {
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
    $okHosts = @($items | ForEach-Object { $_['host'] } | Sort-Object -Unique).Count
    return @{ items = $items; errors = $failed; summary = @{ hosts = $Computers.Count; ok = $okHosts; failed = $failed.Count } }
}

function Global:Assert-HermesModuleRoot {
    # The pinned-module folder is code that runs as the admin account, so only SYSTEM and Administrators
    # may own or write to it. -Create makes it (and its parent) with a protected, administrators-only ACL;
    # an existing root is re-ACLed only when an administrator already owns it. Without -Create this only checks.
    param([switch]$Create)
    $base = Join-Path $env:ProgramData 'HermesSysadmin'
    $root = Join-Path $base 'Modules'
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $admins = New-Object $sidType 'S-1-5-32-544'
    $system = New-Object $sidType 'S-1-5-18'
    $trusted = @($admins.Value, $system.Value)
    $lockDown = {
        param([string]$Path)
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        foreach ($sid in @($admins, $system)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        $acl.SetOwner($admins)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    $ownerOk = {
        param([string]$Path)
        $o = (Get-Acl -LiteralPath $Path).GetOwner($sidType)
        return ($null -ne $o -and $trusted -contains $o.Value)
    }
    if ($Create) {
        foreach ($dir in @($base, $root)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                & $lockDown $dir
            } elseif ($dir -eq $root) {
                if (-not (& $ownerOk $dir)) { throw "UnsafeModuleRoot: $dir exists but is not owned by Administrators or SYSTEM; remove it or take ownership as an administrator." }
                & $lockDown $dir
            }
        }
    }
    if (-not (Test-Path -LiteralPath $root)) { throw "UnsafeModuleRoot: $root does not exist." }
    if (-not (& $ownerOk $root)) { throw "UnsafeModuleRoot: $root is not owned by Administrators or SYSTEM." }
    # write, append, create, delete, change-permissions, take-ownership, generic write/all
    $writeMask = 0x500D0156
    foreach ($ace in @((Get-Acl -LiteralPath $root).GetAccessRules($true, $true, $sidType))) {
        if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
        if ($trusted -contains $ace.IdentityReference.Value) { continue }
        if (([int]$ace.FileSystemRights -band $writeMask) -ne 0) {
            throw "UnsafeModuleRoot: $root grants write access to $($ace.IdentityReference.Value)."
        }
    }
}

function Global:Get-HermesModuleRecord {
    # installed.json -> @{ Name = @{ version; package_hash; installed_utc; files = @{ relpath = sha256 } } }
    $file = Join-Path (Join-Path $env:ProgramData 'HermesSysadmin\Modules') 'installed.json'
    $out = @{}
    if (-not (Test-Path -LiteralPath $file)) { return $out }
    try {
        $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) {
            $files = @{}
            if ($p.Value.files) { foreach ($f in $p.Value.files.PSObject.Properties) { $files[$f.Name] = "$($f.Value)" } }
            $out[$p.Name] = @{ version = "$($p.Value.version)"; package_hash = "$($p.Value.package_hash)"; installed_utc = "$($p.Value.installed_utc)"; files = $files }
        }
    } catch { return @{} }
    return $out
}

function Global:Get-HermesFileHashMap {
    # relative path -> SHA256 for every file under $Dir
    param([Parameter(Mandatory)][string]$Dir)
    $base = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
        $map[$f.FullName.Substring($base.Length).TrimStart('\')] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Global:Test-HermesModuleVerified {
    # True only when the root is safe, installed.json records this exact version and package hash, and the
    # files on disk are exactly the files (and SHA256 hashes) recorded at install time.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$PackageHash)
    try { Assert-HermesModuleRoot } catch { return $false }
    $dir = Join-Path (Join-Path $env:ProgramData 'HermesSysadmin\Modules') (Join-Path $Name $Version)
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    $rec = (Get-HermesModuleRecord)[$Name]
    if ($null -eq $rec -or $rec.version -ne $Version -or $rec.package_hash -cne $PackageHash -or $rec.files.Count -eq 0) { return $false }
    $actual = Get-HermesFileHashMap -Dir $dir
    if ($actual.Count -ne $rec.files.Count) { return $false }
    foreach ($k in $rec.files.Keys) {
        if (-not $actual.ContainsKey($k) -or $actual[$k] -ne $rec.files[$k]) { return $false }
    }
    return $true
}

function Global:Use-HermesModule {
    # Import a pinned Gallery module from the plugin-owned folder (Task 4 installs it there).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Version)
    $root = 'C:\ProgramData\HermesSysadmin\Modules'
    if (Test-Path -LiteralPath $root) { Assert-HermesModuleRoot }
    if (-not (Test-Path (Join-Path $root "$Name\$Version"))) {
        throw "NotInstalled: $Name $Version is not installed on the jump host. Install it with catalog_module_install (name: $Name)."
    }
    if (($env:PSModulePath -split ';') -notcontains $root) { $env:PSModulePath = "$root;$env:PSModulePath" }
    Import-Module -Name $Name -RequiredVersion $Version -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
}
