#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:ToolVersion = '0.2.0-rc1'

function ConvertTo-AdapterGuid {
    param([object]$Value)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Invalid adapter GUID.' }
    return $parsed.ToString('D').ToLowerInvariant()
}

function Assert-PhysicalAdapter {
    param([object]$Adapter, [bool]$RequireUp)
    $null = ConvertTo-AdapterGuid $Adapter.InterfaceGuid
    if ($Adapter.HardwareInterface -ne $true -or $Adapter.Virtual -ne $false) { throw 'Only positively identified physical hardware adapters are supported.' }
    if ([string]$Adapter.InterfaceDescription -match '(?i)virtual|zerotier|wintun|wireguard|hyper-v|vmware|vbox|tailscale|tunnel|\bTAP\b|vpn|bridge' -or
        [string]$Adapter.Name -match '(?i)^vEthernet|zerotier|wintun|mihomo|vgate|tailscale|bridge') { throw 'Refusing a virtual, VPN or bridge adapter.' }
    if ([int]$Adapter.ifIndex -le 0) { throw 'Invalid adapter index.' }
    if ($RequireUp -and [string]$Adapter.Status -ne 'Up') { throw 'Adapter must be Up for Fix.' }
}

function Get-CurrentAdapter {
    param([hashtable]$Backend, [string]$Guid, [bool]$RequireRoute)
    $matches = @(& $Backend.GetAdapters | Where-Object { (ConvertTo-AdapterGuid $_.InterfaceGuid) -eq $Guid })
    if ($matches.Count -ne 1) { throw 'Adapter identity no longer resolves uniquely; refusing a write.' }
    $adapter = $matches[0]
    Assert-PhysicalAdapter $adapter $RequireRoute
    if ($RequireRoute -and @(& $Backend.GetRoutes | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex }).Count -eq 0) {
        throw 'Selected physical adapter has no IPv4 default route. Turn TUN off first.'
    }
    return $adapter
}

function Get-ForwardingValue {
    param([hashtable]$Backend, [object]$Adapter)
    $rows = @(& $Backend.GetIpv4 $Adapter)
    if ($rows.Count -ne 1) { throw 'IPv4 interface did not resolve uniquely.' }
    $value = [string]$rows[0].Forwarding
    if ($value -cnotin @('Enabled', 'Disabled')) { throw 'Unexpected IPv4 forwarding state.' }
    return $value
}

function Assert-SafeTopology {
    param([hashtable]$Backend)
    $safety = & $Backend.GetSafetyState
    if ($safety.Known -ne $true) { throw 'Sharing/routing inspection is incomplete. Operation refused.' }
    if (@($safety.Risks).Count -gt 0) { throw ('Protected topology detected: ' + (@($safety.Risks) -join '; ')) }
}

function Assert-Snapshot {
    param([object]$Record, [string]$Guid, [string]$MachineId, [datetime]$Now)
    if ($null -eq $Record) { throw 'No snapshot. Restore cannot guess the original state.' }
    $fields = @('SchemaVersion','ToolVersion','SavedUtc','InterfaceGuid','MachineId','OriginalForwarding','AddressFamily')
    $actual = @($Record.PSObject.Properties.Name)
    foreach ($field in $fields) { if ($actual -cnotcontains $field) { throw ('Snapshot missing field: ' + $field) } }
    if ($Record.SchemaVersion -ne 2 -or [string]$Record.ToolVersion -cnotmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$' -or
        (ConvertTo-AdapterGuid $Record.InterfaceGuid) -cne $Guid -or [string]$Record.MachineId -cne $MachineId -or
        [string]$Record.AddressFamily -cne 'IPv4' -or [string]$Record.OriginalForwarding -cne 'Enabled') { throw 'Snapshot schema, provenance or adapter mismatch.' }
    $saved = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParseExact([string]$Record.SavedUtc, 'o', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$saved) -or $saved.Offset -ne [timespan]::Zero) { throw 'Invalid snapshot UTC timestamp.' }
    if ($saved.UtcDateTime -gt $Now.ToUniversalTime().AddMinutes(5) -or $saved.UtcDateTime -lt $Now.ToUniversalTime().AddDays(-30)) {
        throw 'Snapshot is stale or future dated; manual review required.'
    }
}

function Invoke-VerifiedChange {
    param([hashtable]$Backend, [string]$Guid, [string]$Before, [string]$Target, [bool]$RequireRoute)
    # Windows offers no atomic GUID/route/topology compare-and-set. Re-resolve
    # before each write, but a narrow operating-system provider race remains.
    $adapter = Get-CurrentAdapter $Backend $Guid $RequireRoute
    Assert-SafeTopology $Backend
    if ((Get-ForwardingValue $Backend $adapter) -cne $Before) { throw 'Forwarding changed concurrently; no write attempted.' }
    try {
        & $Backend.SetForwarding $adapter $Target | Out-Null
        $check = Get-CurrentAdapter $Backend $Guid $false
        if ((Get-ForwardingValue $Backend $check) -cne $Target) { throw 'Forwarding verification failed.' }
    } catch {
        $failure = $_.Exception.Message
        try {
            $rollback = Get-CurrentAdapter $Backend $Guid $false
            # A failed read after Set must not prevent compensation. Identity
            # is still positively checked; write the known pre-operation value.
            $current = $null
            try { $current = Get-ForwardingValue $Backend $rollback } catch { }
            if ($current -cne $Before) {
                # Restore compensation can disable forwarding again. Refuse
                # that compensation if a new sharing dependency appeared.
                if ($Before -ceq 'Disabled') { Assert-SafeTopology $Backend }
                & $Backend.SetForwarding $rollback $Before | Out-Null
            }
            $check = Get-CurrentAdapter $Backend $Guid $false
            if ((Get-ForwardingValue $Backend $check) -cne $Before) { throw 'Rollback verification failed.' }
        } catch {
            throw ('Change failed: ' + $failure + '; ROLLBACK FAILED: ' + $_.Exception.Message + '. Snapshot retained. Stop and review locally.')
        }
        throw ('Change failed: ' + $failure + '; original state verified after rollback. Snapshot retained.')
    }
}

function Invoke-TunForwarding {
    [CmdletBinding()]
    param(
        [ValidateSet('Diagnose','Fix','Restore')][string]$Mode = 'Diagnose',
        [string]$InterfaceAlias = '',
        [Parameter(Mandatory = $true)][hashtable]$Backend
    )
    foreach ($key in @('IsAdministrator','GetAdapters','GetRoutes','GetIpv4','GetSafetyState','SetForwarding',
        'Confirm','GetMachineId','ReadSnapshot','WriteSnapshot','DeleteSnapshot','Now')) {
        if (-not $Backend.ContainsKey($key) -or $Backend[$key] -isnot [scriptblock]) { throw ('Missing backend operation: ' + $key) }
    }
    if ($Backend.ContainsKey('BeginOperation') -or $Backend.ContainsKey('EndOperation')) {
        if (-not $Backend.ContainsKey('BeginOperation') -or -not $Backend.ContainsKey('EndOperation') -or
            $Backend.BeginOperation -isnot [scriptblock] -or $Backend.EndOperation -isnot [scriptblock]) { throw 'Backend lock operations must be a complete scriptblock pair.' }
    }
    if ($Mode -eq 'Diagnose') {
        $adapters = @(& $Backend.GetAdapters)
        $ipv4 = @(foreach ($a in $adapters) {
            try { [pscustomobject]@{ Name = $a.Name; Forwarding = Get-ForwardingValue $Backend $a } }
            catch { [pscustomobject]@{ Name = $a.Name; Forwarding = 'Unknown' } }
        })
        return [pscustomobject]@{ Adapters = $adapters; Ipv4 = $ipv4; Routes = @(& $Backend.GetRoutes); Safety = (& $Backend.GetSafetyState) }
    }
    if (-not (& $Backend.IsAdministrator)) { throw 'Open PowerShell as Administrator and run Fix/Restore again. Automatic UAC relaunch is disabled.' }
    $locked = $false
    try {
        if ($Backend.ContainsKey('BeginOperation')) { & $Backend.BeginOperation | Out-Null; $locked = $true }
        if ([string]::IsNullOrWhiteSpace($InterfaceAlias)) {
            if (-not $Backend.ContainsKey('ReadAlias')) { throw 'An exact physical adapter name is required.' }
            $InterfaceAlias = & $Backend.ReadAlias
        }
        $selected = @(& $Backend.GetAdapters | Where-Object { [string]$_.Name -ceq $InterfaceAlias })
        if ($selected.Count -ne 1) { throw 'Adapter name did not resolve uniquely.' }
        $guid = ConvertTo-AdapterGuid $selected[0].InterfaceGuid
        $a = Get-CurrentAdapter $Backend $guid ($Mode -eq 'Fix')
        $before = Get-ForwardingValue $Backend $a
        if ($Mode -eq 'Fix' -and $before -ceq 'Disabled') { return [pscustomobject]@{ Message = 'Already Disabled. No change and no new snapshot.' } }
        $machine = [string](& $Backend.GetMachineId)
        if ([string]::IsNullOrWhiteSpace($machine)) { throw 'Machine identity unavailable.' }
        $saved = & $Backend.ReadSnapshot $guid
        if ($Mode -eq 'Fix') {
            if ($null -ne $saved) { throw 'Existing snapshot requires Restore or manual review before another Fix.' }
            $target = 'Disabled'
        } else {
            Assert-Snapshot $saved $guid $machine (& $Backend.Now)
            $target = [string]$saved.OriginalForwarding
            if ($before -ceq $target) {
                # A crash before Set or a successful compensating rollback can
                # leave a valid snapshot with the original state already active.
                if (-not (& $Backend.Confirm 'RESTORE')) { throw 'Cancelled: snapshot cleanup confirmation missing.' }
                $check = Get-CurrentAdapter $Backend $guid $false
                if ((Get-ForwardingValue $Backend $check) -cne $target) { throw 'Forwarding changed during confirmation; snapshot retained.' }
                try { & $Backend.DeleteSnapshot $guid | Out-Null }
                catch { throw 'Original forwarding verified, but snapshot cleanup failed. Snapshot retained; do not repeat Fix.' }
                return [pscustomobject]@{ Message = 'Already at saved original state. Confirmed snapshot cleanup; no forwarding write.' }
            }
        }
        Assert-SafeTopology $Backend
        if (-not (& $Backend.Confirm 'NO-SHARING')) { throw 'Cancelled: topology confirmation missing.' }
        if (-not (& $Backend.Confirm $Mode.ToUpperInvariant())) { throw 'Cancelled: operation confirmation missing.' }
        $a = Get-CurrentAdapter $Backend $guid ($Mode -eq 'Fix')
        Assert-SafeTopology $Backend
        if ((Get-ForwardingValue $Backend $a) -cne $before) { throw 'Forwarding changed during confirmation; operation refused.' }
        if ($Mode -eq 'Fix') {
            $saved = [pscustomobject][ordered]@{
                SchemaVersion = 2; ToolVersion = $script:ToolVersion; SavedUtc = (& $Backend.Now).ToUniversalTime().ToString('o')
                InterfaceGuid = $guid; MachineId = $machine; OriginalForwarding = $before; AddressFamily = 'IPv4'
            }
            & $Backend.WriteSnapshot $guid $saved | Out-Null
            $persisted = & $Backend.ReadSnapshot $guid
            Assert-Snapshot $persisted $guid $machine (& $Backend.Now)
            if ([string]$persisted.SavedUtc -cne [string]$saved.SavedUtc) { throw 'Snapshot read-back differs; no settings changed.' }
        }
        Invoke-VerifiedChange $Backend $guid $before $target ($Mode -eq 'Fix')
        if ($Mode -eq 'Restore') {
            try { & $Backend.DeleteSnapshot $guid | Out-Null }
            catch { throw 'Original forwarding verified, but snapshot cleanup failed. Snapshot retained; do not repeat Fix.' }
        }
        return [pscustomobject]@{ Message = ('Verified: ' + $a.Name + ' IPv4 Forwarding ' + $before + ' => ' + $target + '. This verifies the setting, not TUN connectivity.') }
    } finally { if ($locked) { & $Backend.EndOperation | Out-Null } }
}

function Get-WindowsSafetyState {
    $risks = New-Object System.Collections.Generic.List[string]
    $known = $true
    $sharing = $null
    try {
        $sharing = New-Object -ComObject HNetCfg.HNetShare -ErrorAction Stop
        foreach ($connection in @($sharing.EnumEveryConnection())) {
            if ($sharing.INetSharingConfigurationForINetConnection($connection).SharingEnabled) { $risks.Add('Active ICS / Mobile Hotspot sharing') }
        }
    } catch { $known = $false; $risks.Add('ICS inspection unavailable') }
    finally {
        if ($null -ne $sharing -and [Runtime.InteropServices.Marshal]::IsComObject($sharing)) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($sharing) | Out-Null }
    }
    try {
        foreach ($name in @('SharedAccess','icssvc','RemoteAccess')) {
            $services = @(Get-Service -Name $name -ErrorAction SilentlyContinue)
            if ($services.Count -ne 1) { $known = $false; $risks.Add('Service inspection incomplete: ' + $name) }
            elseif ([string]$services[0].Status -ne 'Stopped') { $risks.Add('Sharing/routing service is not stopped: ' + $name) }
        }
        $routing = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction Stop
        $enabled = $routing.PSObject.Properties['IPEnableRouter']
        if ($null -ne $enabled -and [int]$enabled.Value -ne 0) { $risks.Add('Machine-wide IPv4 routing is enabled') }
        $bridges = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
            [string]$_.InterfaceDescription -match '(?i)bridge|MAC Bridge' -or [string]$_.Name -match '(?i)bridge|网桥'
        })
        if ($bridges.Count -gt 0) { $risks.Add('Network bridge detected') }
        if (-not (Get-Command Get-NetNat -ErrorAction SilentlyContinue)) { $known = $false; $risks.Add('NAT inspection unavailable') }
        elseif (@(Get-NetNat -ErrorAction Stop).Count -gt 0) { $risks.Add('Windows NAT configuration detected') }
    } catch { $known = $false; $risks.Add('Routing/bridge/NAT inspection incomplete') }
    return [pscustomobject]@{ Known = $known; Risks = @($risks.ToArray()) }
}

function Assert-TrustedSnapshotAcl {
    param([object]$Acl, [bool]$RequireProtected)
    if ($Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-32-544','S-1-5-18')) { throw 'Untrusted snapshot owner.' }
    if ($RequireProtected -and -not $Acl.AreAccessRulesProtected) { throw 'Snapshot directory ACL must disable inherited permissions.' }
    $rules = @($Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0) { throw 'Empty or null snapshot DACL is not trusted.' }
    $fullControl = @{}
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq 'Allow') {
            if ($rule.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18')) { throw 'Snapshot grants access outside SYSTEM/Administrators.' }
            if (($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl) {
                $fullControl[$rule.IdentityReference.Value] = $true
            }
        }
    }
    if (-not $fullControl.ContainsKey('S-1-5-32-544') -or -not $fullControl.ContainsKey('S-1-5-18')) { throw 'Required snapshot access rules are missing.' }
}

function Assert-TrustedSnapshotFolder {
    param([string]$Folder, [bool]$Create)
    $adminSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    foreach ($path in @((Split-Path -Parent $Folder), $Folder)) {
        if (-not (Test-Path -LiteralPath $path)) {
            if (-not $Create) { return $false }
            $directory = New-Item -ItemType Directory -Path $path -ErrorAction Stop
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Snapshot directory is a link.' }
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($true, $false)
            $acl.SetOwner($adminSid)
            foreach ($sid in @($adminSid, $systemSid)) {
                $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Untrusted snapshot directory.' }
        $existing = Get-Acl -LiteralPath $path -ErrorAction Stop
        Assert-TrustedSnapshotAcl $existing $true
    }
    return $true
}

function Assert-TrustedSnapshotFile {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint -or $item.Length -gt 65536) { throw 'Invalid snapshot file.' }
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    Assert-TrustedSnapshotAcl $acl $false
}

function ConvertFrom-SnapshotJson {
    param([string]$Json)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ($Json | ConvertFrom-Json -DateKind String -ErrorAction Stop)
    }
    $record = $Json | ConvertFrom-Json -ErrorAction Stop
    # PowerShell 7.0-7.4 deserialize ISO strings as DateTime. The toolkit
    # always writes UTC 'Z'; do not normalize an ambiguous Local/Unspecified
    # value. PowerShell 5.1 already preserves the string.
    if ($null -ne $record -and $null -ne $record.PSObject.Properties['SavedUtc'] -and $record.SavedUtc -is [datetime]) {
        if ($record.SavedUtc.Kind -ne [DateTimeKind]::Utc) { throw 'Snapshot timestamp lost unambiguous UTC identity.' }
        $record.SavedUtc = $record.SavedUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $record
}

function New-WindowsBackend {
    # Construction does not perform network/filesystem inspection or writes.
    $script:StorageFolder = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'MihomoTunForwardingToolkit\Snapshots-v2'
    $script:SnapshotEntropy = [Text.Encoding]::UTF8.GetBytes('MihomoTunForwardingToolkit/snapshot/v2')
    $script:OperationMutex = $null
    return @{
        IsAdministrator = {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try { (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
            finally { $identity.Dispose() }
        }
        GetAdapters = { @(Get-NetAdapter -IncludeHidden -ErrorAction Stop) }
        GetRoutes = { @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction Stop) }
        GetIpv4 = { param($a) @(Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop) }
        GetSafetyState = { Get-WindowsSafetyState }
        SetForwarding = {
            param($a, $target)
            $live = @(Get-NetAdapter -InterfaceIndex $a.ifIndex -IncludeHidden -ErrorAction Stop)
            if ($live.Count -ne 1 -or (ConvertTo-AdapterGuid $live[0].InterfaceGuid) -cne (ConvertTo-AdapterGuid $a.InterfaceGuid)) { throw 'Interface index was reassigned.' }
            Assert-PhysicalAdapter $live[0] $false
            Set-NetIPInterface -InterfaceIndex $live[0].ifIndex -AddressFamily IPv4 -Forwarding $target -PolicyStore ActiveStore -ErrorAction Stop
        }
        ReadAlias = {
            Get-NetAdapter -Physical -ErrorAction Stop | Format-Table Name,Status -AutoSize | Out-Host
            Read-Host 'Turn TUN off. Enter the exact physical Wi-Fi/Ethernet adapter name'
        }
        Confirm = {
            param($action)
            Write-Warning 'Do not proceed if any client depends on forwarding, sharing, a hotspot or a bridge. Third-party subnet routing cannot be fully detected.'
            (Read-Host ('Type ' + $action + ' to confirm')) -ceq $action
        }
        GetMachineId = { [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid }
        Now = { [datetime]::UtcNow }
        BeginOperation = {
            $script:OperationMutex = New-Object Threading.Mutex($false, 'Global\MihomoTunForwardingToolkitV2')
            try { $acquired = $script:OperationMutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { $script:OperationMutex.Dispose(); $script:OperationMutex = $null; throw 'Another toolkit operation is running.' }
        }
        EndOperation = {
            if ($null -ne $script:OperationMutex) { $script:OperationMutex.ReleaseMutex(); $script:OperationMutex.Dispose(); $script:OperationMutex = $null }
        }
        ReadSnapshot = {
            param($guid)
            if (-not (Assert-TrustedSnapshotFolder $script:StorageFolder $false)) { return $null }
            $path = Join-Path $script:StorageFolder ((ConvertTo-AdapterGuid $guid) + '.bin')
            if (-not (Test-Path -LiteralPath $path)) { return $null }
            Assert-TrustedSnapshotFile $path
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $script:SnapshotEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
            $json = [Text.Encoding]::UTF8.GetString($bytes)
            ConvertFrom-SnapshotJson $json
        }
        WriteSnapshot = {
            param($guid,$record)
            $null = Assert-TrustedSnapshotFolder $script:StorageFolder $true
            $path = Join-Path $script:StorageFolder ((ConvertTo-AdapterGuid $guid) + '.bin')
            if (Test-Path -LiteralPath $path) { throw 'Snapshot already exists; never overwrite it.' }
            Add-Type -AssemblyName System.Security -ErrorAction Stop
            $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 4 -Compress))
            $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $script:SnapshotEntropy, [Security.Cryptography.DataProtectionScope]::LocalMachine)
            $temporary = Join-Path $script:StorageFolder ([guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $stream.Write($protected, 0, $protected.Length); $stream.Flush($true) } finally { $stream.Dispose() }
                $fileAcl = Get-Acl -LiteralPath $temporary -ErrorAction Stop
                $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
                Set-Acl -LiteralPath $temporary -AclObject $fileAcl -ErrorAction Stop
                Assert-TrustedSnapshotFile $temporary
                [IO.File]::Move($temporary, $path)
            } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -ErrorAction Stop } }
            Write-Host ('Recovery snapshot: ' + $path)
        }
        DeleteSnapshot = {
            param($guid)
            $null = Assert-TrustedSnapshotFolder $script:StorageFolder $false
            $path = Join-Path $script:StorageFolder ((ConvertTo-AdapterGuid $guid) + '.bin')
            Assert-TrustedSnapshotFile $path
            Remove-Item -LiteralPath $path -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function Invoke-TunForwarding, New-WindowsBackend
