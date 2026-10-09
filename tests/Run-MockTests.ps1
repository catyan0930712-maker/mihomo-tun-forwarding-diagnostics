#Requires -Version 5.1
<#
These tests inject every backend operation. They never construct the Windows
backend, elevate, inspect real network adapters, or change real network settings.
No Pester installation or download is required. Run in a fresh PowerShell process.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'scripts/TunForwarding.Core.psm1'
$script:passed = 0
$script:failures = New-Object 'System.Collections.Generic.List[string]'
$global:TunForwardingTestTripwireCalls = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) {
        throw "Assertion failed: $Message (expected <$Expected>, actual <$Actual>)"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$MessagePattern = '')
    $caught = $false
    $message = ''
    try { & $Action | Out-Null } catch { $caught = $true; $message = $_.Exception.Message }
    Assert-True $caught 'Operation must reject with an exception'
    if ($MessagePattern) { Assert-True ($message -match $MessagePattern) ('Failure must report: ' + $MessagePattern) }
}

function Assert-NoMutation {
    param($Fixture)
    Assert-Equal 0 $Fixture.State.SetCalls.Count 'No forwarding writes'
    Assert-Equal 0 $Fixture.State.WriteCount 'No snapshot writes'
    Assert-Equal 0 $Fixture.State.DeleteCount 'No snapshot deletion'
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Assert-Equal 0 $global:TunForwardingTestTripwireCalls.Count 'No real system command invoked'
        $script:passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:failures.Add("$Name : $($_.Exception.Message)")
        Write-Host "FAIL $Name : $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-FakeFixture {
    $adapter = [pscustomobject]@{
        Name = 'WLAN'
        ifIndex = 5
        InterfaceGuid = '11111111-2222-3333-4444-555555555555'
        InterfaceDescription = 'Mock physical Wi-Fi adapter'
        Status = 'Up'
        HardwareInterface = $true
        Virtual = $false
    }
    $state = @{
        Administrator = $true
        Adapters = @($adapter)
        Routes = @([pscustomobject]@{ InterfaceIndex = 5 })
        Forwarding = 'Enabled'
        SafetyKnown = $true
        Risks = @()
        MachineId = 'mock-machine-001'
        Clock = [datetime]::Parse('2026-10-10T00:00:00Z', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Snapshots = @{}
        ConfirmResponses = @{}
        ConfirmCalls = New-Object 'System.Collections.Generic.List[string]'
        SetCalls = New-Object 'System.Collections.Generic.List[object]'
        OperationCalls = New-Object 'System.Collections.Generic.List[string]'
        AdapterReadCount = 0
        IpReadCount = 0
        SnapshotReadCount = 0
        WriteCount = 0
        DeleteCount = 0
        BeginCount = 0
        EndCount = 0
        LockHeld = $false
        BeginThrows = $false
        Hook = $null
        SetThrowAt = @()
        SetApplyBeforeThrow = $false
        SetIgnoreAt = @()
        WriteBehavior = 'Normal'
        DeleteThrows = $false
    }
    $backend = @{
        IsAdministrator = {
            $state.OperationCalls.Add('IsAdministrator')
            if ($state.Hook) { & $state.Hook 'IsAdministrator' $state }
            return $state.Administrator
        }.GetNewClosure()
        GetAdapters = {
            $state.AdapterReadCount++
            $state.OperationCalls.Add('GetAdapters')
            if ($state.Hook) { & $state.Hook 'GetAdapters' $state }
            # Copy records: in-place fake changes must not silently alter a
            # previously selected adapter or hide a stale-interface-index bug.
            foreach ($a in $state.Adapters) {
                [pscustomobject]@{
                    Name = $a.Name; ifIndex = $a.ifIndex
                    InterfaceGuid = $a.InterfaceGuid
                    InterfaceDescription = $a.InterfaceDescription
                    Status = $a.Status; HardwareInterface = $a.HardwareInterface
                    Virtual = $a.Virtual
                }
            }
        }.GetNewClosure()
        GetRoutes = {
            $state.OperationCalls.Add('GetRoutes')
            if ($state.Hook) { & $state.Hook 'GetRoutes' $state }
            return @($state.Routes)
        }.GetNewClosure()
        GetIpv4 = {
            param($SelectedAdapter)
            $state.IpReadCount++
            $state.OperationCalls.Add('GetIpv4')
            if ($state.Hook) { & $state.Hook 'GetIpv4' $state }
            $matches = @($state.Adapters | Where-Object {
                $_.InterfaceGuid -eq $SelectedAdapter.InterfaceGuid -and $_.ifIndex -eq $SelectedAdapter.ifIndex
            })
            if ($matches.Count -ne 1) { throw 'Fake backend: stale or ambiguous adapter identity/index' }
            return [pscustomobject]@{ Forwarding = $state.Forwarding }
        }.GetNewClosure()
        GetSafetyState = {
            $state.OperationCalls.Add('GetSafetyState')
            if ($state.Hook) { & $state.Hook 'GetSafetyState' $state }
            return [pscustomobject]@{ Known = $state.SafetyKnown; Risks = @($state.Risks) }
        }.GetNewClosure()
        SetForwarding = {
            param($SelectedAdapter, $Target)
            $state.OperationCalls.Add('SetForwarding')
            if ($state.Hook) { & $state.Hook 'SetForwarding' $state }
            $matches = @($state.Adapters | Where-Object {
                $_.InterfaceGuid -eq $SelectedAdapter.InterfaceGuid -and $_.ifIndex -eq $SelectedAdapter.ifIndex
            })
            if ($matches.Count -ne 1) { throw 'Fake backend: stale or ambiguous write identity/index' }
            $state.SetCalls.Add([pscustomobject]@{
                Guid = [string]$SelectedAdapter.InterfaceGuid; Index = $SelectedAdapter.ifIndex
                Target = [string]$Target; Before = $state.Forwarding
                SnapshotPresent = $state.Snapshots.ContainsKey(([guid]$SelectedAdapter.InterfaceGuid).ToString('D'))
            })
            $call = $state.SetCalls.Count
            if ($state.SetThrowAt -contains $call) {
                if ($state.SetApplyBeforeThrow) { $state.Forwarding = [string]$Target }
                throw "Fake setter failure $call"
            }
            if ($state.SetIgnoreAt -notcontains $call) { $state.Forwarding = [string]$Target }
        }.GetNewClosure()
        Confirm = {
            param([string]$Action)
            $state.OperationCalls.Add('Confirm:' + $Action)
            $state.ConfirmCalls.Add($Action)
            if ($state.Hook) { & $state.Hook ('Confirm:' + $Action) $state }
            if ($state.ConfirmResponses.ContainsKey($Action)) { return [bool]$state.ConfirmResponses[$Action] }
            return $true
        }.GetNewClosure()
        GetMachineId = {
            $state.OperationCalls.Add('GetMachineId')
            if ($state.Hook) { & $state.Hook 'GetMachineId' $state }
            return $state.MachineId
        }.GetNewClosure()
        ReadSnapshot = {
            param($Guid)
            $state.SnapshotReadCount++
            $state.OperationCalls.Add('ReadSnapshot')
            if ($state.Hook) { & $state.Hook 'ReadSnapshot' $state }
            if ($state.WriteBehavior -eq 'MissingReadback' -and $state.WriteCount -gt 0) { return $null }
            $key = ([guid]$Guid).ToString('D')
            if (-not $state.Snapshots.ContainsKey($key)) { return $null }
            $copy = $state.Snapshots[$key] | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            # Match the Windows backend's DateKind String compatibility path:
            # newer PowerShell JSON parsers otherwise deserialize ISO dates.
            $copy.SavedUtc = [string]$state.Snapshots[$key].SavedUtc
            if ($state.WriteBehavior -eq 'TamperedReadback' -and $state.WriteCount -gt 0) {
                $copy.MachineId = 'different-machine'
            }
            return $copy
        }.GetNewClosure()
        WriteSnapshot = {
            param($Guid, $Record)
            $state.WriteCount++
            $state.OperationCalls.Add('WriteSnapshot')
            if ($state.Hook) { & $state.Hook 'WriteSnapshot' $state }
            if ($state.WriteBehavior -eq 'Throw') { throw 'Fake snapshot write failure' }
            $key = ([guid]$Guid).ToString('D')
            if ($state.Snapshots.ContainsKey($key)) { throw 'Fake snapshot refuses overwrite' }
            $state.Snapshots[$key] = $Record | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $state.Snapshots[$key].SavedUtc = [string]$Record.SavedUtc
        }.GetNewClosure()
        DeleteSnapshot = {
            param($Guid)
            $state.DeleteCount++
            $state.OperationCalls.Add('DeleteSnapshot')
            if ($state.Hook) { & $state.Hook 'DeleteSnapshot' $state }
            if ($state.DeleteThrows) { throw 'Fake snapshot deletion failure' }
            $state.Snapshots.Remove(([guid]$Guid).ToString('D'))
        }.GetNewClosure()
        Now = { return $state.Clock }.GetNewClosure()
        BeginOperation = {
            $state.BeginCount++
            $state.OperationCalls.Add('BeginOperation')
            if ($state.BeginThrows) { throw 'Fake operation lock already held' }
            $state.LockHeld = $true
        }.GetNewClosure()
        EndOperation = {
            $state.EndCount++
            $state.OperationCalls.Add('EndOperation')
            $state.LockHeld = $false
        }.GetNewClosure()
    }
    return [pscustomobject]@{ Backend = $backend; State = $state; Adapter = $adapter }
}

function Add-ValidSnapshot {
    param($Fixture)
    $record = [pscustomobject]@{
        SchemaVersion = 2
        ToolVersion = '0.2.0-rc1'
        SavedUtc = $Fixture.State.Clock.ToString('o')
        InterfaceGuid = $Fixture.Adapter.InterfaceGuid
        MachineId = $Fixture.State.MachineId
        OriginalForwarding = 'Enabled'
        AddressFamily = 'IPv4'
    }
    $Fixture.State.Snapshots[([guid]$Fixture.Adapter.InterfaceGuid).ToString('D')] = $record
    return $record
}

function Invoke-Fake {
    param($Fixture, [string]$Mode = 'Fix', [string]$Alias = 'WLAN')
    Invoke-TunForwarding -Mode $Mode -InterfaceAlias $Alias -Backend $Fixture.Backend | Out-Null
}

function New-FixtureForMode {
    param([string]$Mode)
    $fixture = New-FakeFixture
    if ($Mode -eq 'Restore') {
        Add-ValidSnapshot $fixture | Out-Null
        $fixture.State.Forwarding = 'Disabled'
    }
    return $fixture
}

function New-FakeAclRule {
    param([string]$Sid, [string]$Access = 'Allow', [Security.AccessControl.FileSystemRights]$Rights = 'FullControl')
    return [pscustomobject]@{
        IdentityReference = [pscustomobject]@{ Value = $Sid }
        AccessControlType = $Access
        FileSystemRights = $Rights
    }
}

function New-FakeAcl {
    $acl = [pscustomobject]@{
        OwnerSid = 'S-1-5-32-544'
        AreAccessRulesProtected = $true
        Rules = @((New-FakeAclRule 'S-1-5-32-544'), (New-FakeAclRule 'S-1-5-18'))
    }
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value {
        param($Type)
        return [pscustomobject]@{ Value = $this.OwnerSid }
    }
    $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value {
        param($Explicit, $Inherited, $Type)
        return @($this.Rules)
    }
    return $acl
}

function Invoke-FakeAclCheck {
    param($Acl, [bool]$RequireProtected = $true)
    # This pure validator consumes only fake ACL records, never Get-Acl/Set-Acl.
    & (Get-Module -Name 'TunForwarding.Core') {
        param($FakeAcl, $Protected)
        Assert-TrustedSnapshotAcl $FakeAcl $Protected
    } $Acl $RequireProtected
}

function Invoke-FakeSnapshotJsonParse {
    param([string]$Json, [bool]$Legacy = $false, [string]$SimulatedKind = '')
    # The module-scoped overrides live only in this invocation scope. The
    # production parser is exercised without constructing the Windows backend.
    & (Get-Module -Name 'TunForwarding.Core') {
        param($Text, $ForceLegacy, $DateKind)
        if ($ForceLegacy) {
            function Get-Command {
                param([string]$Name)
                return [pscustomobject]@{ Parameters = @{} }
            }
        }
        if ($DateKind) {
            $date = [datetime]::SpecifyKind([datetime]::Parse('2026-10-10T00:00:00', [cultureinfo]::InvariantCulture),
                [DateTimeKind]$DateKind)
            $reader = {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)][string]$InputObject)
                process { return [pscustomobject]@{ SavedUtc = $date } }
            }.GetNewClosure()
            Set-Item -LiteralPath 'Function:ConvertFrom-Json' -Value $reader
        }
        ConvertFrom-SnapshotJson $Text
    } $Json $Legacy $SimulatedKind
}

# The tripwires shadow both mutating commands and real adapter reads. Even an
# accidental Windows-backend invocation should fail before contacting the system.
$tripwireNames = @(
    'Set-NetIPInterface', 'Get-NetAdapter', 'Get-NetRoute', 'Get-NetIPInterface',
    'Get-NetNat', 'Get-Service', 'Get-ItemProperty', 'netsh', 'Start-Process',
    'Enable-NetAdapter', 'Disable-NetAdapter', 'Set-NetAdapter',
    'New-NetRoute', 'Set-NetRoute', 'Remove-NetRoute',
    'Set-DnsClientServerAddress', 'Set-NetFirewallProfile',
    'Invoke-WebRequest', 'Invoke-RestMethod', 'Get-Acl', 'Set-Acl'
)
$originalFunctions = @{}
try {
    foreach ($name in $tripwireNames) {
        $path = 'Function:global:' + $name
        if (Test-Path -LiteralPath $path) { $originalFunctions[$name] = (Get-Item -LiteralPath $path).ScriptBlock }
        $tripwireName = $name
        $guard = {
            $global:TunForwardingTestTripwireCalls.Add($tripwireName)
            throw "Tripwire: forbidden real system command $tripwireName"
        }.GetNewClosure()
        Set-Item -LiteralPath $path -Value $guard
    }
    Import-Module -Name $modulePath -Force
    Assert-Equal 0 $global:TunForwardingTestTripwireCalls.Count 'Import must not execute real system operations'

    Invoke-TestCase 'Diagnose is read-only without administrator' {
        $f = New-FakeFixture
        $f.State.Administrator = $false
        Invoke-Fake $f 'Diagnose'
        Assert-NoMutation $f
        Assert-Equal 0 $f.State.ConfirmCalls.Count 'No confirmation or elevation for Diagnose'
        Assert-Equal 0 $f.State.BeginCount 'Diagnose does not acquire mutation lock'
    }
    Invoke-TestCase 'Fix saves schema-2 snapshot before one IPv4 write' {
        $f = New-FakeFixture
        Invoke-Fake $f
        Assert-Equal 'Disabled' $f.State.Forwarding 'Fix target'
        Assert-Equal 1 $f.State.SetCalls.Count 'Only one forwarding write'
        Assert-Equal 'Disabled' $f.State.SetCalls[0].Target 'Only IPv4 target value'
        Assert-True $f.State.SetCalls[0].SnapshotPresent 'Snapshot exists at mutation time'
        Assert-Equal 1 $f.State.WriteCount 'One snapshot created'
        Assert-Equal 0 $f.State.DeleteCount 'Keep restoration record after Fix'
        Assert-True ($f.State.SnapshotReadCount -ge 2) 'Snapshot must be read back before mutation'
        $record = $f.State.Snapshots[$f.Adapter.InterfaceGuid]
        Assert-Equal 2 $record.SchemaVersion 'Snapshot schema'
        Assert-Equal $f.Adapter.InterfaceGuid $record.InterfaceGuid 'Stable GUID recorded'
        Assert-Equal $f.State.MachineId $record.MachineId 'Machine identity recorded'
        Assert-Equal 'Enabled' $record.OriginalForwarding 'Original forwarding recorded'
        Assert-Equal 'IPv4' $record.AddressFamily 'Address family bounded'
        Assert-Equal 'NO-SHARING,FIX' ($f.State.ConfirmCalls -join ',') 'Two explicit confirmations'
        Assert-Equal 1 $f.State.BeginCount 'Operation lock acquired'
        Assert-Equal 1 $f.State.EndCount 'Operation lock released'
        Assert-True (-not $f.State.LockHeld) 'No lock left held after success'
    }
    Invoke-TestCase 'Fix already Disabled is no-op' {
        $f = New-FakeFixture; $f.State.Forwarding = 'Disabled'
        Invoke-Fake $f
        Assert-NoMutation $f
    }
    Invoke-TestCase 'Fix twice cannot overwrite restoration evidence' {
        $f = New-FakeFixture
        Invoke-Fake $f
        $saved = $f.State.Snapshots[$f.Adapter.InterfaceGuid] | ConvertTo-Json
        $f.State.Forwarding = 'Enabled'
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 1 $f.State.SetCalls.Count 'Second Fix cannot write'
        Assert-Equal 1 $f.State.WriteCount 'Second Fix cannot replace snapshot'
        Assert-Equal $saved ($f.State.Snapshots[$f.Adapter.InterfaceGuid] | ConvertTo-Json) 'Original evidence unchanged'
    }
    Invoke-TestCase 'Fix refuses preexisting snapshot' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
    }
    foreach ($mode in @('Fix', 'Restore')) {
        Invoke-TestCase "$mode requires administrator without elevation" {
            $f = New-FixtureForMode $mode
            $f.State.Administrator = $false
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses virtual flag" {
            $f = New-FixtureForMode $mode
            $f.Adapter.Virtual = $true
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode requires HardwareInterface" {
            $f = New-FixtureForMode $mode
            $f.Adapter.HardwareInterface = $false
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses suspicious adapter description" {
            $f = New-FixtureForMode $mode
            $f.Adapter.InterfaceDescription = 'ZeroTier Virtual Port'
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses invalid GUID" {
            $f = New-FakeFixture; $f.Adapter.InterfaceGuid = 'bad-guid'
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses ambiguous alias" {
            $f = New-FakeFixture
            $second = $f.Adapter | Select-Object *
            $second.InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            $f.State.Adapters += $second
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses nonexistent alias" {
            $f = New-FakeFixture
            Assert-Throws { Invoke-Fake $f $mode 'missing' }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses unknown forwarding value" {
            $f = New-FixtureForMode $mode
            $f.State.Forwarding = 'Unknown'
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses unknown safety state" {
            $f = New-FixtureForMode $mode
            $f.State.SafetyKnown = $false
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode refuses detected shared-routing risks" {
            $f = New-FixtureForMode $mode
            $f.State.Risks = @('ICS', 'Mobile Hotspot', 'NAT', 'bridge')
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode rejects denied NO-SHARING confirmation" {
            $f = New-FixtureForMode $mode
            $f.State.ConfirmResponses['NO-SHARING'] = $false
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
        Invoke-TestCase "$mode rejects denied action confirmation" {
            $f = New-FixtureForMode $mode
            $f.State.ConfirmResponses[$mode.ToUpperInvariant()] = $false
            Assert-Throws { Invoke-Fake $f $mode }; Assert-NoMutation $f
        }
    }
    foreach ($newSafety in @('Risk', 'Unknown')) {
        Invoke-TestCase "Restore compensation refuses new sharing state: $newSafety" {
            $f = New-FixtureForMode 'Restore'
            $f.State.NewSafety = $newSafety
            $f.State.Hook = {
                param($operation, $s)
                if ($operation -eq 'GetIpv4' -and $s.SetCalls.Count -gt 0) {
                    if ($s.NewSafety -eq 'Risk') { $s.Risks = @('ICS became active') }
                    else { $s.SafetyKnown = $false }
                    throw 'Fake post-write IPv4 read failure'
                }
            }
            Assert-Throws { Invoke-Fake $f 'Restore' } 'ROLLBACK FAILED'
            Assert-Equal 1 $f.State.SetCalls.Count 'Do not disable forwarding after new sharing dependency'
            Assert-Equal 'Enabled' $f.State.Forwarding 'Restored forwarding remains enabled'
            Assert-Equal 0 $f.State.DeleteCount 'Unverified compensation preserves evidence'
            Assert-Equal 1 $f.State.Snapshots.Count 'Snapshot retained for manual review'
        }
    }
    Invoke-TestCase 'Fix compensation can re-enable original forwarding after topology becomes unknown' {
        $f = New-FakeFixture
        $f.State.Hook = {
            param($operation, $s)
            if ($operation -eq 'GetIpv4' -and $s.SetCalls.Count -gt 0) {
                $s.SafetyKnown = $false
                throw 'Fake post-write IPv4 read failure'
            }
        }
        Assert-Throws { Invoke-Fake $f } 'ROLLBACK FAILED'
        Assert-Equal 2 $f.State.SetCalls.Count 'Known original Enabled value can still be compensated'
        Assert-Equal 'Enabled' $f.State.SetCalls[1].Target 'Compensation restores forwarding'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Original state restored despite unreadable verification'
        Assert-Equal 1 $f.State.Snapshots.Count 'Unverified state retains snapshot'
    }
    Invoke-TestCase 'Fix refuses disconnected physical adapter' {
        $f = New-FakeFixture; $f.Adapter.Status = 'Disconnected'
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
    }
    Invoke-TestCase 'Fix refuses physical adapter without default route' {
        $f = New-FakeFixture; $f.State.Routes = @()
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
    }
    Invoke-TestCase 'Fix refuses empty machine identity' {
        $f = New-FakeFixture; $f.State.MachineId = ''
        Assert-Throws { Invoke-Fake $f }; Assert-Equal 0 $f.State.SetCalls.Count 'No write with missing machine identity'
    }
    foreach ($behavior in @('Throw', 'MissingReadback', 'TamperedReadback')) {
        Invoke-TestCase "Fix refuses snapshot persistence failure: $behavior" {
            $f = New-FakeFixture; $f.State.WriteBehavior = $behavior
            Assert-Throws { Invoke-Fake $f }
            Assert-Equal 0 $f.State.SetCalls.Count 'No modification before verified durable snapshot'
        }
    }
    Invoke-TestCase 'Fix rejects GUID replacement after confirmation' {
        $f = New-FakeFixture
        $f.State.Hook = {
            param($operation, $s)
            if ($operation -eq 'Confirm:FIX') { $s.Adapters[0].InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
        }
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 0 $f.State.SetCalls.Count 'Never modify replacement adapter'
    }
    Invoke-TestCase 'Fix re-resolves GUID when interface index changes' {
        $f = New-FakeFixture
        $f.State.Hook = {
            param($operation, $s)
            if ($operation -eq 'Confirm:FIX') {
                $s.Adapters[0].ifIndex = 42
                $s.Routes = @([pscustomobject]@{ InterfaceIndex = 42 })
            }
        }
        Invoke-Fake $f
        Assert-Equal 42 $f.State.SetCalls[0].Index 'Write uses current index for same GUID'
    }
    Invoke-TestCase 'Fix rejects changed forwarding before write' {
        $f = New-FakeFixture
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:FIX') { $s.Forwarding = 'Disabled' } }
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 0 $f.State.SetCalls.Count 'Do not overwrite concurrent state change'
    }
    Invoke-TestCase 'Fix rechecks safety after confirmation' {
        $f = New-FakeFixture
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:FIX') { $s.Risks = @('ICS') } }
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 0 $f.State.SetCalls.Count 'No write when sharing becomes active'
    }
    Invoke-TestCase 'Fix rechecks physical identity after confirmation' {
        $f = New-FakeFixture
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:FIX') { $s.Adapters[0].HardwareInterface = $false } }
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 0 $f.State.SetCalls.Count 'No write after physical status changes'
    }
    Invoke-TestCase 'Fix verification failure verifies already-original rollback state' {
        $f = New-FakeFixture; $f.State.SetIgnoreAt = @(1)
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 1 $f.State.SetCalls.Count 'No redundant write if already back at original state'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Original forwarding maintained'
        Assert-True ($f.State.Snapshots.Count -gt 0) 'Recovery evidence retained'
    }
    Invoke-TestCase 'Fix setter error after partial write rolls back' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 2 $f.State.SetCalls.Count 'Rollback attempted after setter exception'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Rollback restored original'
        Assert-True ($f.State.Snapshots.Count -gt 0) 'Snapshot retained after failed operation'
    }
    Invoke-TestCase 'Fix rollback failure preserves evidence and reports failure' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1, 2); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 2 $f.State.SetCalls.Count 'Rollback was attempted'
        Assert-True ($f.State.Snapshots.Count -gt 0) 'Snapshot retained when rollback setter fails'
        Assert-Equal 0 $f.State.DeleteCount 'Failed rollback cannot erase evidence'
    }
    Invoke-TestCase 'Fix handles localized literal alias without wildcard interpretation' {
        $f = New-FakeFixture
        $literalName = ([string][char]0x65E0) + [char]0x7EBF + ' [Wi-Fi] ''quoted'''
        $f.Adapter.Name = $literalName
        Invoke-Fake $f 'Fix' $literalName
        Assert-Equal 'Disabled' $f.State.Forwarding 'Unicode literal selection works'
        Assert-Equal 1 $f.State.SetCalls.Count 'Only selected interface modified'
    }
    Invoke-TestCase 'Restore uses valid GUID snapshot and deletes only after verification' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        Invoke-Fake $f 'Restore'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Restored original'
        Assert-Equal 1 $f.State.SetCalls.Count 'One restore write'
        Assert-Equal 1 $f.State.DeleteCount 'Snapshot deleted once'
        Assert-Equal 0 $f.State.Snapshots.Count 'Recovery record consumed after successful restore'
        Assert-Equal 'NO-SHARING,RESTORE' ($f.State.ConfirmCalls -join ',') 'Restore has two explicit confirmations'
        $setIndex = $f.State.OperationCalls.IndexOf('SetForwarding')
        $deleteIndex = $f.State.OperationCalls.IndexOf('DeleteSnapshot')
        Assert-True ($deleteIndex -gt $setIndex) 'Deletion is after mutation'
        Assert-True ($f.State.IpReadCount -ge 3) 'State read before write and verified before deletion'
    }
    Invoke-TestCase 'Restore permits offline physical adapter without default route' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        $f.State.Forwarding = 'Disabled'; $f.Adapter.Status = 'Disconnected'; $f.State.Routes = @()
        Invoke-Fake $f 'Restore'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Offline restore reaches original value'
    }
    Invoke-TestCase 'Restore already-original requires confirmation then only clears snapshot' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        Invoke-Fake $f 'Restore'
        Assert-Equal 0 $f.State.SetCalls.Count 'No forwarding writes for already-original state'
        Assert-Equal 0 $f.State.WriteCount 'No new snapshot'
        Assert-Equal 1 $f.State.DeleteCount 'Confirmed cleanup removes obsolete evidence'
        Assert-Equal 0 $f.State.Snapshots.Count 'Record consumed only after explicit confirmation'
        Assert-Equal 'RESTORE' ($f.State.ConfirmCalls -join ',') 'Cleanup requires explicit RESTORE'
    }
    Invoke-TestCase 'Restore already-original cleanup ignores topology without network writes' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        $f.State.SafetyKnown = $false; $f.State.Risks = @('ICS'); $f.State.Routes = @(); $f.Adapter.Status = 'Disconnected'
        Invoke-Fake $f 'Restore'
        Assert-Equal 0 $f.State.SetCalls.Count 'Protected topology receives no network write'
        Assert-Equal 0 $f.State.Snapshots.Count 'Explicit safe cleanup completes'
    }
    Invoke-TestCase 'Restore already-original denied cleanup keeps evidence' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        $f.State.ConfirmResponses['RESTORE'] = $false
        Assert-Throws { Invoke-Fake $f 'Restore' }; Assert-NoMutation $f
        Assert-Equal 1 $f.State.Snapshots.Count 'Cancel retains snapshot'
    }
    Invoke-TestCase 'Restore already-original cleanup failure keeps evidence' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.DeleteThrows = $true
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 0 $f.State.SetCalls.Count 'Cleanup failure cannot write network'
        Assert-Equal 1 $f.State.Snapshots.Count 'Failed deletion retains recovery record'
    }
    Invoke-TestCase 'Restore already-original cleanup rejects concurrent state change' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:RESTORE') { $s.Forwarding = 'Disabled' } }
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-NoMutation $f
    }
    Invoke-TestCase 'Restore already-original cleanup rejects replacement device' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:RESTORE') { $s.Adapters[0].InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' } }
        Assert-Throws { Invoke-Fake $f 'Restore' }; Assert-NoMutation $f
    }
    Invoke-TestCase 'Restore refuses missing snapshot' {
        $f = New-FakeFixture; $f.State.Forwarding = 'Disabled'
        Assert-Throws { Invoke-Fake $f 'Restore' }; Assert-NoMutation $f
    }
    $invalidSnapshotCases = @(
        @{ Name = 'legacy schema'; Field = 'SchemaVersion'; Value = 1 },
        @{ Name = 'future schema'; Field = 'SchemaVersion'; Value = 3 },
        @{ Name = 'wrong adapter GUID'; Field = 'InterfaceGuid'; Value = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' },
        @{ Name = 'wrong machine'; Field = 'MachineId'; Value = 'wrong-machine' },
        @{ Name = 'missing machine'; Field = 'MachineId'; Value = '' },
        @{ Name = 'IPv6 family'; Field = 'AddressFamily'; Value = 'IPv6' },
        @{ Name = 'invalid family'; Field = 'AddressFamily'; Value = '' },
        @{ Name = 'Disabled original'; Field = 'OriginalForwarding'; Value = 'Disabled' },
        @{ Name = 'unknown original'; Field = 'OriginalForwarding'; Value = 'Maybe' },
        @{ Name = 'unparseable timestamp'; Field = 'SavedUtc'; Value = 'not-a-date' },
        @{ Name = 'old snapshot'; Field = 'SavedUtc'; Value = '2026-09-09T00:00:00.0000000Z' },
        @{ Name = 'future snapshot'; Field = 'SavedUtc'; Value = '2026-10-10T00:05:01.0000000Z' },
        @{ Name = 'non-UTC timestamp'; Field = 'SavedUtc'; Value = '2026-10-10T00:00:00.0000000+01:00' },
        @{ Name = 'malformed tool version'; Field = 'ToolVersion'; Value = 'not-semver' },
        @{ Name = 'empty tool version'; Field = 'ToolVersion'; Value = '' }
    )
    foreach ($item in $invalidSnapshotCases) {
        Invoke-TestCase ('Restore rejects ' + $item.Name) {
            $f = New-FakeFixture; $record = Add-ValidSnapshot $f; $f.State.Forwarding = 'Disabled'
            $record.($item.Field) = $item.Value
            Assert-Throws { Invoke-Fake $f 'Restore' }; Assert-NoMutation $f
        }
    }
    Invoke-TestCase 'Restore accepts snapshot exactly 30 days old' {
        $f = New-FakeFixture; $record = Add-ValidSnapshot $f; $f.State.Forwarding = 'Disabled'
        $record.SavedUtc = $f.State.Clock.AddDays(-30).ToString('o')
        Invoke-Fake $f 'Restore'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Age boundary is accepted'
    }
    Invoke-TestCase 'Restore accepts compatible schema-2 snapshot from older tool version' {
        $f = New-FakeFixture; $record = Add-ValidSnapshot $f; $f.State.Forwarding = 'Disabled'
        $record.ToolVersion = '0.1.0-rc2'
        Invoke-Fake $f 'Restore'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Same schema can restore across tool versions'
    }
    Invoke-TestCase 'Restore accepts clock skew exactly five minutes' {
        $f = New-FakeFixture; $record = Add-ValidSnapshot $f; $f.State.Forwarding = 'Disabled'
        $record.SavedUtc = $f.State.Clock.AddMinutes(5).ToString('o')
        Invoke-Fake $f 'Restore'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Clock skew boundary is accepted'
    }
    Invoke-TestCase 'Restore rejects GUID replacement after confirmation' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:RESTORE') { $s.Adapters[0].InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' } }
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 0 $f.State.SetCalls.Count 'No restore to replacement device'
        Assert-Equal 0 $f.State.DeleteCount 'Keep original recovery record'
    }
    Invoke-TestCase 'Restore re-resolves GUID when interface index changes' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:RESTORE') { $s.Adapters[0].ifIndex = 42 } }
        Invoke-Fake $f 'Restore'
        Assert-Equal 42 $f.State.SetCalls[0].Index 'Restore writes current index'
    }
    Invoke-TestCase 'Restore refuses concurrent forwarding change' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.Hook = { param($operation, $s) if ($operation -eq 'Confirm:RESTORE') { $s.Forwarding = 'Enabled' } }
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 0 $f.State.SetCalls.Count 'Do not overwrite concurrent change'
        Assert-Equal 0 $f.State.DeleteCount 'Keep evidence on conflict'
    }
    Invoke-TestCase 'Restore setter error rolls back to Disabled and retains snapshot' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.SetThrowAt = @(1); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 2 $f.State.SetCalls.Count 'Restore failure triggers rollback'
        Assert-Equal 'Disabled' $f.State.SetCalls[1].Target 'Rollback target is immediate before state'
        Assert-Equal 'Disabled' $f.State.Forwarding 'Failed restore returns original current state'
        Assert-True ($f.State.Snapshots.Count -gt 0) 'Evidence retained'
    }
    Invoke-TestCase 'Restore verification failure retains snapshot' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.SetIgnoreAt = @(1)
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 'Disabled' $f.State.Forwarding 'Rollback preserves immediate state'
        Assert-Equal 0 $f.State.DeleteCount 'Unverified restore cannot consume snapshot'
    }
    Invoke-TestCase 'Restore rollback setter failure cannot erase snapshot' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.SetThrowAt = @(1, 2); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-Equal 2 $f.State.SetCalls.Count 'Rollback attempted'
        Assert-Equal 0 $f.State.DeleteCount 'Record retained'
    }
    Invoke-TestCase 'Restore snapshot deletion failure leaves recovery evidence' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.Forwarding = 'Disabled'
        $f.State.DeleteThrows = $true
        Assert-Throws { Invoke-Fake $f 'Restore' }
        Assert-True ($f.State.Snapshots.Count -gt 0) 'Failed cleanup preserves recovery evidence'
        Assert-Equal 'Enabled' $f.State.Forwarding 'Verified restore remains restored when cleanup fails'
        Assert-Equal 1 $f.State.SetCalls.Count 'Cleanup failure does not change forwarding again'
    }
    foreach ($mode in @('Fix', 'Restore')) {
        Invoke-TestCase "$mode persistent post-write read failure still attempts compensation" {
            $f = New-FixtureForMode $mode
            $before = $f.State.Forwarding
            $f.State.Hook = {
                param($operation, $s)
                if ($operation -eq 'GetIpv4' -and $s.SetCalls.Count -gt 0) { throw 'Fake persistent IPv4 read failure' }
            }
            Assert-Throws { Invoke-Fake $f $mode } 'ROLLBACK FAILED'
            Assert-Equal 2 $f.State.SetCalls.Count 'Read failure cannot block compensation setter'
            Assert-Equal $before $f.State.SetCalls[1].Target 'Compensate to known immediate before value'
            Assert-Equal $before $f.State.Forwarding 'Fake confirms compensation setter applied'
            Assert-Equal 0 $f.State.DeleteCount 'Unverified rollback preserves record'
            Assert-True ($f.State.Snapshots.Count -gt 0) 'Snapshot retained'
        }
        Invoke-TestCase "$mode rollback cannot write a GUID replacement device" {
            $f = New-FixtureForMode $mode
            $f.State.Hook = {
                param($operation, $s)
                if ($operation -eq 'GetAdapters' -and $s.SetCalls.Count -gt 0) {
                    $s.Adapters[0].InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
                }
            }
            Assert-Throws { Invoke-Fake $f $mode } 'ROLLBACK FAILED'
            Assert-Equal 1 $f.State.SetCalls.Count 'No compensation write to replacement device'
            Assert-Equal 0 $f.State.DeleteCount 'Identity failure preserves evidence'
        }
    }
    Invoke-TestCase 'Fix after failed mutation can proceed after confirmed snapshot cleanup' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 'Enabled' $f.State.Forwarding 'Failed Fix rolled back'
        $f.State.SetThrowAt = @()
        Invoke-Fake $f 'Restore'
        Assert-Equal 2 $f.State.SetCalls.Count 'Already-original cleanup does not add network write'
        Assert-Equal 0 $f.State.Snapshots.Count 'Cleanup removes blocker'
        Invoke-Fake $f 'Fix'
        Assert-Equal 'Disabled' $f.State.Forwarding 'A subsequent confirmed Fix works'
        Assert-Equal 3 $f.State.SetCalls.Count 'Only one new write'
    }
    Invoke-TestCase 'Incomplete injected backend cannot fall through to real operations' {
        $f = New-FakeFixture; $f.Backend.Remove('SetForwarding')
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
    }
    Invoke-TestCase 'Operation lock contention refuses all mutations' {
        $f = New-FakeFixture; $f.State.BeginThrows = $true
        Assert-Throws { Invoke-Fake $f }
        Assert-NoMutation $f
        Assert-Equal 1 $f.State.BeginCount 'Lock acquisition attempted'
        Assert-Equal 0 $f.State.EndCount 'Do not release a lock that was never acquired'
    }
    Invoke-TestCase 'Operation lock releases on topology rejection' {
        $f = New-FakeFixture; $f.State.SafetyKnown = $false
        Assert-Throws { Invoke-Fake $f }
        Assert-NoMutation $f
        Assert-Equal 1 $f.State.EndCount 'finally releases lock on rejection'
        Assert-True (-not $f.State.LockHeld) 'No lock leak'
    }
    Invoke-TestCase 'Operation lock releases on forwarding setter failure' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1); $f.State.SetApplyBeforeThrow = $true
        Assert-Throws { Invoke-Fake $f }
        Assert-Equal 1 $f.State.EndCount 'finally releases lock on rollback path'
        Assert-True (-not $f.State.LockHeld) 'No lock leak after failure'
    }
    Invoke-TestCase 'Operation lock releases on no-op' {
        $f = New-FakeFixture; $f.State.Forwarding = 'Disabled'
        Invoke-Fake $f
        Assert-NoMutation $f
        Assert-Equal 1 $f.State.EndCount 'finally releases lock on early return'
    }
    Invoke-TestCase 'Incomplete optional lock pair is rejected before mutation' {
        $f = New-FakeFixture; $f.Backend.Remove('EndOperation')
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
        Assert-Equal 0 $f.State.BeginCount 'Do not acquire a lock that cannot be released'
    }
    Invoke-TestCase 'Non-scriptblock lock release is rejected before mutation' {
        $f = New-FakeFixture; $f.Backend.EndOperation = 'not-a-scriptblock'
        Assert-Throws { Invoke-Fake $f }; Assert-NoMutation $f
    }
    Invoke-TestCase 'JSON snapshot round-trip preserves exact UTC text' {
        $f = New-FakeFixture
        Invoke-Fake $f
        $record = & $f.Backend.ReadSnapshot $f.Adapter.InterfaceGuid
        Assert-True ($record.SavedUtc -is [string]) 'ISO snapshot timestamp remains a string'
        Assert-Equal $f.State.Clock.ToString('o') $record.SavedUtc 'UTC timestamp round-trips identically'
    }
    Invoke-TestCase 'Production JSON parser preserves UTC text on current engine' {
        $record = Invoke-FakeSnapshotJsonParse '{"SavedUtc":"2026-10-10T00:00:00.0000000Z"}'
        Assert-True ($record.SavedUtc -is [string]) 'Production parser returns timestamp as string'
        Assert-Equal '2026-10-10T00:00:00.0000000Z' $record.SavedUtc 'Production timestamp round-trip'
    }
    Invoke-TestCase 'Production JSON parser legacy branch preserves real UTC round-trip' {
        $record = Invoke-FakeSnapshotJsonParse '{"SavedUtc":"2026-10-10T00:00:00.0000000Z"}' $true
        Assert-True ($record.SavedUtc -is [string]) 'Legacy parser normalizes automatic DateTime values'
        Assert-Equal '2026-10-10T00:00:00.0000000Z' $record.SavedUtc 'Legacy timestamp round-trip'
    }
    Invoke-TestCase 'Production JSON parser legacy branch normalizes UTC DateTime object' {
        $record = Invoke-FakeSnapshotJsonParse '{}' $true 'Utc'
        Assert-Equal '2026-10-10T00:00:00.0000000Z' $record.SavedUtc 'Simulated legacy UTC DateTime is canonicalized'
    }
    foreach ($kind in @('Local', 'Unspecified')) {
        Invoke-TestCase "Production JSON parser legacy branch rejects $kind DateTime object" {
            Assert-Throws { Invoke-FakeSnapshotJsonParse '{}' $true $kind } 'unambiguous UTC'
        }
    }
    Invoke-TestCase 'Pure ACL validator accepts trusted administrator and SYSTEM permissions' {
        $acl = New-FakeAcl
        Invoke-FakeAclCheck $acl
    }
    Invoke-TestCase 'Pure ACL validator rejects empty DACL' {
        $acl = New-FakeAcl; $acl.Rules = @()
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator rejects null DACL' {
        $acl = New-FakeAcl; $acl.Rules = $null
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator rejects Everyone access' {
        $acl = New-FakeAcl; $acl.Rules += (New-FakeAclRule 'S-1-1-0')
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator rejects non-administrator owner' {
        $acl = New-FakeAcl; $acl.OwnerSid = 'S-1-5-21-100-200-300-1001'
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator rejects inherited directory permissions' {
        $acl = New-FakeAcl; $acl.AreAccessRulesProtected = $false
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator allows file inheritance when every rule is trusted' {
        $acl = New-FakeAcl; $acl.AreAccessRulesProtected = $false
        Invoke-FakeAclCheck $acl $false
    }
    Invoke-TestCase 'Pure ACL validator requires administrator FullControl' {
        $acl = New-FakeAcl
        $acl.Rules = @((New-FakeAclRule 'S-1-5-32-544' 'Allow' 'ReadAndExecute'), (New-FakeAclRule 'S-1-5-18'))
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator requires SYSTEM FullControl' {
        $acl = New-FakeAcl; $acl.Rules = @((New-FakeAclRule 'S-1-5-32-544'))
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
    Invoke-TestCase 'Pure ACL validator does not count deny rules as granted access' {
        $acl = New-FakeAcl
        $acl.Rules = @((New-FakeAclRule 'S-1-5-32-544' 'Deny'), (New-FakeAclRule 'S-1-5-18'))
        Assert-Throws { Invoke-FakeAclCheck $acl }
    }
}
finally {
    Remove-Module -Name 'TunForwarding.Core' -ErrorAction SilentlyContinue
    foreach ($name in $tripwireNames) {
        $path = 'Function:global:' + $name
        if ($originalFunctions.ContainsKey($name)) {
            Set-Item -LiteralPath $path -Value $originalFunctions[$name]
        }
        else { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    $tripwireCount = $global:TunForwardingTestTripwireCalls.Count
    Remove-Variable -Name TunForwardingTestTripwireCalls -Scope Global -ErrorAction SilentlyContinue
}

Write-Host "Mock tests: $script:passed passed, $($script:failures.Count) failed; real system calls: $tripwireCount."
if ($script:failures.Count -gt 0 -or $tripwireCount -gt 0) {
    throw ($script:failures -join [Environment]::NewLine)
}
