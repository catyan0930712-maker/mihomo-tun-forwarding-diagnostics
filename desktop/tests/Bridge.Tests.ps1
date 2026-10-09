#Requires -Version 5.1
# Full fake backend only: no production backend, adapter queries or network writes.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$desktop = Split-Path -Parent $PSScriptRoot
$root = Split-Path -Parent $desktop
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$global:DesktopBridgeTripwires = New-Object 'System.Collections.Generic.List[string]'

function Assert-Bridge {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-BridgeCase {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Assert-Bridge ($global:DesktopBridgeTripwires.Count -eq 0) 'A real system command was invoked.'
        $script:Passed++
        Write-Host ('PASS ' + $Name)
    }
    catch {
        $script:Failures.Add($Name + ': ' + $_.Exception.Message)
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function Get-BridgeResult {
    param($Fixture, [string]$Mode = 'Fix', [string]$Expected = 'Enabled', [object]$NoSharing = $true,
        [object]$Confirmed = $true, [string]$Guid = '', [string]$Alias = '')
    if (-not $Guid) { $Guid = [string]$Fixture.Adapter.InterfaceGuid }
    if (-not $Alias) { $Alias = [string]$Fixture.Adapter.Name }
    $output = @(Invoke-DesktopAction -Mode $Mode -InterfaceGuid $Guid -InterfaceAlias $Alias -ExpectedForwarding $Expected -NoSharingConfirmed $NoSharing -ActionConfirmed $Confirmed -Backend $Fixture.Backend)
    Assert-Bridge ($output.Count -eq 1 -and $output[0] -is [string]) 'Action must output exactly one JSON string.'
    return ($output[0] | ConvertFrom-Json)
}

function Assert-NoBridgeWrites {
    param($Fixture)
    Assert-Bridge ($Fixture.State.SetCalls.Count -eq 0 -and $Fixture.State.WriteCount -eq 0 -and $Fixture.State.DeleteCount -eq 0) 'Unexpected network or snapshot mutation.'
}

$guardNames = @('Get-NetAdapter', 'Get-NetRoute', 'Get-NetIPInterface', 'Set-NetIPInterface', 'Get-NetNat',
    'Get-Service', 'Get-ItemProperty', 'Get-Acl', 'Set-Acl', 'Read-Host', 'Start-Process', 'netsh',
    'Enable-NetAdapter', 'Disable-NetAdapter', 'Set-NetAdapter', 'New-NetRoute', 'Set-NetRoute',
    'Remove-NetRoute', 'Set-DnsClientServerAddress', 'Invoke-WebRequest', 'Invoke-RestMethod')
$savedFunctions = @{}
try {
    foreach ($name in $guardNames) {
        $path = 'Function:global:' + $name
        if (Test-Path -LiteralPath $path) { $savedFunctions[$name] = (Get-Item -LiteralPath $path).ScriptBlock }
        $guardName = $name
        Set-Item -LiteralPath $path -Value {
            $global:DesktopBridgeTripwires.Add($guardName)
            throw ('Real system command blocked: ' + $guardName)
        }.GetNewClosure()
    }
    # Reuse only the established suite's fake factory definitions. Do not
    # dot-source that executable test file or its real command wiring.
    $tokens = $null; $parseErrors = $null
    $factoryAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tests/Run-MockTests.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw 'Fake fixture source failed to parse.' }
    foreach ($factory in @('New-FakeFixture', 'Add-ValidSnapshot', 'New-FixtureForMode')) {
        $found = @($factoryAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $factory }, $true))
        if ($found.Count -ne 1) { throw ('Fake fixture definition not unique: ' + $factory) }
        . ([scriptblock]::Create($found[0].Extent.Text))
    }
    . (Join-Path $desktop 'Engine/DesktopBridge.ps1')
    Initialize-DesktopEngine -CoreScriptText ([IO.File]::ReadAllText((Join-Path $desktop 'Engine/TunForwarding.Core.psm1')))
    Assert-Bridge ($global:DesktopBridgeTripwires.Count -eq 0) 'Bridge initialization must not inspect the system.'

    Test-BridgeCase 'Embedded core exactly matches the established safety engine' {
        $original = (Get-FileHash -LiteralPath (Join-Path $root 'scripts/TunForwarding.Core.psm1') -Algorithm SHA256).Hash
        $embedded = (Get-FileHash -LiteralPath (Join-Path $desktop 'Engine/TunForwarding.Core.psm1') -Algorithm SHA256).Hash
        Assert-Bridge ($original -ceq $embedded) 'The safety engine was changed.'
    }
    Test-BridgeCase 'Read-only status produces one JSON value and hides addresses/machine identity' {
        $f = New-FakeFixture
        $f.State.Routes[0] | Add-Member -NotePropertyName NextHop -NotePropertyValue '192.0.2.123'
        $output = @(Invoke-DesktopStatus -Backend $f.Backend)
        Assert-Bridge ($output.Count -eq 1 -and $output[0] -is [string]) 'Status output is not pure JSON.'
        $r = $output[0] | ConvertFrom-Json
        Assert-Bridge ($r.Success -and $r.Adapters.Count -eq 1) 'Status should succeed.'
        Assert-Bridge ($r.Adapters[0].CanFix -and $r.Adapters[0].PhysicalEligible) 'Physical fix eligibility was not computed.'
        Assert-Bridge ($r.Adapters[0].Snapshot.State -ceq 'Absent') 'Absent snapshot was not identified.'
        Assert-Bridge ($r.Adapters[0].Snapshot.Reason -ceq 'NoSnapshot') 'An inspected absence needs a distinct reason.'
        Assert-Bridge ($r.Adapters[0].ForwardingReadError -ceq '' -and $r.Adapters[0].DefaultRouteReadError -ceq '') 'Successful property reads must not have failure text.'
        Assert-Bridge ($output[0] -notmatch '192\.0\.2\.123|mock-machine-001|MachineId|NextHop') 'Private routing/provenance leaked.'
        Assert-NoBridgeWrites $f
        Assert-Bridge ($f.State.BeginCount -eq 0) 'Status should not acquire a mutation lock.'
    }
    Test-BridgeCase 'Non-admin snapshot access remains Unknown rather than Absent' {
        $f = New-FakeFixture; $f.State.Administrator = $false; Add-ValidSnapshot $f | Out-Null
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        $snapshot = $r.Adapters[0].Snapshot
        Assert-Bridge ($snapshot.State -ceq 'Unknown' -and -not $snapshot.Known -and $null -eq $snapshot.Present -and $null -eq $snapshot.Valid) 'Unknown access must not imply a missing snapshot.'
        Assert-Bridge ($snapshot.Reason -ceq 'AdministratorRequired' -and $snapshot.Message -match 'not inspected') 'A non-admin record needs an explicit not-inspected reason.'
        Assert-Bridge ($f.State.SnapshotReadCount -eq 0) 'Non-admin status should not read protected snapshots.'
        Assert-Bridge (-not $r.Adapters[0].CanFix -and -not $r.Adapters[0].CanRestore) 'Non-admin actions must be disabled.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Present valid snapshot is validated and can restore' {
        $f = New-FixtureForMode 'Restore'
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Adapters[0].Snapshot.State -ceq 'Valid' -and $r.Adapters[0].Snapshot.Valid -and $r.Adapters[0].CanRestore) 'Valid snapshot was not verified.'
        Assert-Bridge ($r.Adapters[0].Snapshot.Reason -ceq 'Validated') 'Validated provenance needs a distinct reason.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Present mismatched snapshot is Invalid and cannot restore' {
        $f = New-FixtureForMode 'Restore'; $f.State.Snapshots[$f.Adapter.InterfaceGuid].MachineId = 'other-private-machine'
        $json = Invoke-DesktopStatus -Backend $f.Backend; $r = $json | ConvertFrom-Json
        Assert-Bridge ($r.Adapters[0].Snapshot.State -ceq 'Invalid' -and $r.Adapters[0].Snapshot.Present -and -not $r.Adapters[0].CanRestore) 'Untrusted snapshot should not be eligible.'
        Assert-Bridge ($r.Adapters[0].Snapshot.Reason -ceq 'ValidationFailed') 'Invalid provenance must differ from unreadable storage.'
        Assert-Bridge ($json -notmatch 'other-private-machine') 'Snapshot machine identity leaked.'
    }
    Test-BridgeCase 'Snapshot read failure stays Unknown' {
        $f = New-FakeFixture; $f.State.Hook = { param($op, $s) if ($op -eq 'ReadSnapshot') { throw 'Mock access denied' } }
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Adapters[0].Snapshot.State -ceq 'Unknown' -and $null -eq $r.Adapters[0].Snapshot.Present) 'Access failure must remain unknown.'
        Assert-Bridge ($r.Adapters[0].Snapshot.Reason -ceq 'ReadFailed' -and $r.Adapters[0].Snapshot.Message -match 'Mock access denied') 'Snapshot failure must preserve its actual provider reason.'
        Assert-Bridge (-not $r.Adapters[0].CanFix) 'Cannot fix without snapshot access.'
    }
    Test-BridgeCase 'Unknown route and safety states block status eligibility' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'GetRoutes' -or $op -eq 'GetSafetyState') { throw 'Mock query unavailable' } }
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge (-not $r.Adapters[0].DefaultRouteKnown -and -not $r.Safety.Known -and -not $r.Adapters[0].CanFix) 'Unavailable queries must not appear safe.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Forwarding read failure reports the provider reason without addresses or writes' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'GetIpv4') { throw 'Mock access denied at 192.0.2.8 and 2001:db8::8' } }
        $json = Invoke-DesktopStatus -Backend $f.Backend; $r = $json | ConvertFrom-Json
        $a = $r.Adapters[0]
        Assert-Bridge ($r.Success -and $a.Forwarding -ceq 'Unknown' -and $a.ForwardingReadError -match 'Mock access denied') 'A property-read failure must remain Unknown with its cause.'
        Assert-Bridge (($r.Messages -join ' ') -match 'IPv4 forwarding inspection failed for WLAN') 'The failure needs a locatable adapter context.'
        Assert-Bridge ($json -notmatch '192\.0\.2\.8|2001:db8::8') 'Provider error addresses must be redacted.'
        Assert-Bridge (-not $a.CanFix -and -not $a.CanRestore) 'Unknown forwarding must not authorize an action.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Unexpected forwarding values have a readable validation reason' {
        $f = New-FakeFixture; $f.State.Forwarding = 'Unexpected'
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Success -and $r.Adapters[0].Forwarding -ceq 'Unknown' -and $r.Adapters[0].ForwardingReadError -match 'Unexpected IPv4 forwarding state') 'Invalid provider values must not look like an empty Unknown.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Route read failure preserves its reason while other inspected values stay available' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'GetRoutes') { throw 'Mock CIM route access denied at 198.51.100.4' } }
        $json = Invoke-DesktopStatus -Backend $f.Backend; $r = $json | ConvertFrom-Json
        $a = $r.Adapters[0]
        Assert-Bridge ($r.Success -and -not $a.DefaultRouteKnown -and -not $a.HasDefaultRoute -and $a.DefaultRouteReadError -match 'Mock CIM route access denied') 'Unknown route must carry its actual failure reason.'
        Assert-Bridge ($a.Forwarding -ceq 'Enabled' -and $r.Safety.Known -and -not $a.CanFix) 'Route failure must not discard independent reads or permit Fix.'
        Assert-Bridge (($r.Messages -join ' ') -match 'Mock CIM route access denied' -and $json -notmatch '198\.51\.100\.4') 'Route diagnostics must preserve reason and redact addresses.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Thrown sharing inspection preserves the actual reason and remains blocked' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'GetSafetyState') { throw 'Mock ICS COM access denied (0x80070005) at 203.0.113.4' } }
        $json = Invoke-DesktopStatus -Backend $f.Backend; $r = $json | ConvertFrom-Json
        Assert-Bridge ($r.Success -and -not $r.Safety.Known -and ($r.Safety.Risks -join ' ') -match '0x80070005') 'Unknown sharing must retain the reported COM failure.'
        Assert-Bridge (($r.Messages -join ' ') -match 'Mock ICS COM access denied' -and $json -notmatch '203\.0\.113\.4') 'Sharing diagnostics must preserve reason and redact addresses.'
        Assert-Bridge (-not $r.Adapters[0].CanFix -and -not $r.Adapters[0].CanRestore) 'Confirmation cannot bypass unknown sharing.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Core sharing finding without exception detail is described without guessing a cause' {
        $f = New-FakeFixture; $f.State.SafetyKnown = $false; $f.State.Risks = @('ICS inspection unavailable')
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        $text = $r.Messages -join ' '
        Assert-Bridge (-not $r.Safety.Known -and $text -match 'did not return an exception detail' -and $text -match 'does not establish that sharing is active') 'An unavailable inspection must not be presented as detected ICS activity.'
        Assert-Bridge ($text -notmatch 'access denied|0x80070005' -and -not $r.Adapters[0].CanFix) 'Missing provider detail must not be invented or bypassed.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Machine identity failure has a distinct reason and never reads snapshots' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'GetMachineId') { throw 'Mock registry permission denied at 192.0.2.55' } }
        $json = Invoke-DesktopStatus -Backend $f.Backend; $r = $json | ConvertFrom-Json
        $snapshot = $r.Adapters[0].Snapshot
        Assert-Bridge ($snapshot.State -ceq 'Unknown' -and $snapshot.Reason -ceq 'MachineIdentityUnavailable' -and $snapshot.Message -match 'Mock registry permission denied') 'Unknown provenance needs its actual cause.'
        Assert-Bridge ($null -eq $snapshot.Present -and $f.State.SnapshotReadCount -eq 0 -and -not $r.Adapters[0].CanFix) 'Unknown provenance must not query storage or permit Fix.'
        Assert-Bridge ($json -notmatch '192\.0\.2\.55|mock-machine-001') 'Provenance diagnostics must not expose addresses or machine identity.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Empty machine identity is distinct from a known missing snapshot' {
        $f = New-FakeFixture; $f.State.MachineId = ''
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Adapters[0].Snapshot.Reason -ceq 'MachineIdentityUnavailable' -and $r.Adapters[0].Snapshot.Message -match 'identifier was empty' -and $f.State.SnapshotReadCount -eq 0) 'Empty identity must remain an uninspected provenance failure.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Administrator status failure never implies an inspected absence' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'IsAdministrator') { throw 'Mock token inspection unavailable' } }
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        $snapshot = $r.Adapters[0].Snapshot
        Assert-Bridge ($r.Success -and -not $r.IsAdministrator -and $snapshot.Reason -ceq 'AdministratorStatusUnavailable' -and $snapshot.Message -match 'Mock token inspection unavailable') 'Privilege lookup failure must be explicitly unknown.'
        Assert-Bridge ($f.State.SnapshotReadCount -eq 0 -and $null -eq $snapshot.Present -and -not $r.Adapters[0].CanRestore) 'Privilege uncertainty must not expose storage or enable actions.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Invalid adapter identity has a distinct snapshot reason' {
        $f = New-FakeFixture; $f.Adapter.InterfaceGuid = 'invalid-guid'
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Success -and -not $r.Adapters[0].PhysicalEligible -and $r.Adapters[0].Snapshot.Reason -ceq 'AdapterIdentityUnavailable' -and $r.Adapters[0].Snapshot.Message -match 'Invalid adapter GUID') 'Adapter identity failure must not be mislabeled as missing storage.'
        Assert-Bridge ($f.State.SnapshotReadCount -eq 0 -and -not $r.Adapters[0].CanFix) 'Invalid adapter identity must remain ineligible.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Disconnected Enabled and Up Disabled are independently reported without enabling writes' {
        $f = New-FakeFixture; $f.State.Administrator = $false
        $ethernet = [pscustomobject]@{ Name = 'Ethernet'; ifIndex = 9; InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'; InterfaceDescription = 'Mock physical Ethernet'; Status = 'Disconnected'; HardwareInterface = $true; Virtual = $false }
        $f.State.Adapters = @($ethernet, $f.Adapter)
        $f.Backend.GetIpv4 = { param($a) [pscustomobject]@{ Forwarding = $(if ($a.Name -ceq 'Ethernet') { 'Enabled' } else { 'Disabled' }) } }
        $r = Invoke-DesktopStatus -Backend $f.Backend | ConvertFrom-Json
        Assert-Bridge ($r.Success -and $r.Adapters.Count -eq 2 -and $r.Adapters[0].Status -ceq 'Disconnected' -and $r.Adapters[0].Forwarding -ceq 'Enabled' -and $r.Adapters[1].Status -ceq 'Up' -and $r.Adapters[1].Forwarding -ceq 'Disabled') 'Link status must not be conflated with the forwarding property.'
        foreach ($a in $r.Adapters) { Assert-Bridge (-not $a.CanFix -and -not $a.CanRestore -and $a.Snapshot.Reason -ceq 'AdministratorRequired') 'Read-only observations must not enable network writes.' }
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Confirmed bound Fix uses the established snapshot/change flow' {
        $f = New-FakeFixture; $r = Get-BridgeResult $f
        Assert-Bridge ($r.Success -and $f.State.Forwarding -ceq 'Disabled') 'Confirmed Fix failed.'
        Assert-Bridge ($f.State.SetCalls.Count -eq 1 -and $f.State.WriteCount -eq 1 -and $f.State.DeleteCount -eq 0) 'Fix transaction was changed.'
        Assert-Bridge ($f.State.ConfirmCalls.Count -eq 0) 'Console confirmation must never be invoked by the UI.'
    }
    foreach ($flag in @('Action', 'Sharing')) {
        Test-BridgeCase ('Missing explicit confirmation refuses Fix: ' + $flag) {
            $f = New-FakeFixture
            if ($flag -eq 'Action') { $r = Get-BridgeResult $f -Confirmed $false }
            else { $r = Get-BridgeResult $f -NoSharing $false }
            Assert-Bridge (-not $r.Success) 'An unconfirmed action must fail.'
            Assert-NoBridgeWrites $f
        }
        Test-BridgeCase ('String Boolean cannot authorize Fix: ' + $flag) {
            $f = New-FakeFixture
            if ($flag -eq 'Action') { $r = Get-BridgeResult $f -Confirmed 'true' }
            else { $r = Get-BridgeResult $f -NoSharing 'true' }
            Assert-Bridge (-not $r.Success) 'String confirmation must not be coerced to true.'
            Assert-NoBridgeWrites $f
        }
    }
    Test-BridgeCase 'Fix without administrator is refused without elevation' {
        $f = New-FakeFixture; $f.State.Administrator = $false
        $r = Get-BridgeResult $f
        Assert-Bridge (-not $r.Success -and $f.State.AdapterReadCount -eq 0) 'Non-admin action should refuse before adapter inspection.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Request GUID cannot select a different adapter with the same name' {
        $f = New-FakeFixture; $r = Get-BridgeResult $f -Guid 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        Assert-Bridge (-not $r.Success) 'Stale displayed GUID must be refused.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Exact alias is bound independently of GUID' {
        $f = New-FakeFixture; $r = Get-BridgeResult $f -Alias 'wlan'
        Assert-Bridge (-not $r.Success) 'Case-mismatched name must be refused.'
        Assert-NoBridgeWrites $f
    }
    Test-BridgeCase 'Changed displayed forwarding requires a fresh confirmation' {
        $f = New-FakeFixture; $f.State.Forwarding = 'Disabled'; $r = Get-BridgeResult $f -Expected 'Enabled'
        Assert-Bridge (-not $r.Success) 'Changed displayed state must be refused.'
        Assert-NoBridgeWrites $f
    }
    foreach ($condition in @('Virtual', 'Offline', 'NoRoute', 'Sharing', 'Unknown')) {
        Test-BridgeCase ('Core refusal is preserved: ' + $condition) {
            $f = New-FakeFixture
            switch ($condition) {
                'Virtual' { $f.Adapter.Virtual = $true }
                'Offline' { $f.Adapter.Status = 'Disconnected' }
                'NoRoute' { $f.State.Routes = @() }
                'Sharing' { $f.State.Risks = @('ICS') }
                'Unknown' { $f.State.SafetyKnown = $false }
            }
            $r = Get-BridgeResult $f
            Assert-Bridge (-not $r.Success) 'A core safety refusal was bypassed.'
            Assert-NoBridgeWrites $f
        }
    }
    foreach ($change in @('Guid', 'Alias', 'Forwarding')) {
        Test-BridgeCase ('Fresh binding rejects race before network write: ' + $change) {
            $f = New-FakeFixture; $f.State.Change = $change
            $f.State.Hook = {
                param($op, $s)
                if ($op -eq 'WriteSnapshot') {
                    switch ($s.Change) {
                        'Guid' { $s.Adapters[0].InterfaceGuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' }
                        'Alias' { $s.Adapters[0].Name = 'Renamed WLAN' }
                        'Forwarding' { $s.Forwarding = 'Disabled' }
                    }
                }
            }
            $r = Get-BridgeResult $f
            Assert-Bridge (-not $r.Success -and $f.State.SetCalls.Count -eq 0) 'A request-binding race wrote the network.'
        }
    }
    Test-BridgeCase 'Fresh GUID binding allows an updated interface index' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'WriteSnapshot') { $s.Adapters[0].ifIndex = 42; $s.Routes = @([pscustomobject]@{ InterfaceIndex = 42 }) } }
        $r = Get-BridgeResult $f
        Assert-Bridge ($r.Success -and $f.State.SetCalls[0].Index -eq 42) 'Updated index for the same confirmed device should work.'
    }
    Test-BridgeCase 'Literal Unicode and quoted alias are never evaluated as code' {
        $f = New-FakeFixture; $f.Adapter.Name = ([string][char]0x65E0) + [char]0x7EBF + ' [x] ''; Start-Process nope; #'
        $r = Get-BridgeResult $f
        Assert-Bridge ($r.Success -and $f.State.SetCalls.Count -eq 1) 'Literal alias handling failed.'
    }
    Test-BridgeCase 'Offline Restore does not need a default route' {
        $f = New-FixtureForMode 'Restore'; $f.Adapter.Status = 'Disconnected'; $f.State.Routes = @()
        $r = Get-BridgeResult $f -Mode 'Restore' -Expected 'Disabled'
        Assert-Bridge ($r.Success -and $f.State.Forwarding -ceq 'Enabled' -and $f.State.DeleteCount -eq 1) 'Offline recovery was weakened.'
    }
    Test-BridgeCase 'Already-original Restore only confirms cleanup and does not require NO-SHARING' {
        $f = New-FakeFixture; Add-ValidSnapshot $f | Out-Null; $f.State.SafetyKnown = $false
        $r = Get-BridgeResult $f -Mode 'Restore' -Expected 'Enabled' -NoSharing $false
        Assert-Bridge ($r.Success -and $f.State.SetCalls.Count -eq 0 -and $f.State.DeleteCount -eq 1) 'No-write cleanup behavior changed.'
    }
    Test-BridgeCase 'Partial-write failure compensates and retains recovery evidence' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1); $f.State.SetApplyBeforeThrow = $true
        $r = Get-BridgeResult $f
        Assert-Bridge (-not $r.Success -and $f.State.Forwarding -ceq 'Enabled' -and $f.State.SetCalls.Count -eq 2 -and $f.State.Snapshots.Count -eq 1) 'Core compensation was bypassed.'
        Assert-Bridge ($f.State.EndCount -eq 1) 'Operation lock leaked.'
    }
    Test-BridgeCase 'Rollback failure is explicit JSON and keeps the snapshot' {
        $f = New-FakeFixture; $f.State.SetThrowAt = @(1, 2); $f.State.SetApplyBeforeThrow = $true
        $r = Get-BridgeResult $f
        Assert-Bridge (-not $r.Success -and $r.RollbackFailed -and $f.State.Snapshots.Count -eq 1) 'Rollback failure was hidden.'
    }
    Test-BridgeCase 'Host messages are collected without corrupting JSON output' {
        $f = New-FakeFixture
        $f.State.Hook = { param($op, $s) if ($op -eq 'WriteSnapshot') { Write-Host 'Recovery snapshot created.'; Write-Warning 'Mock warning at 192.0.2.7' } }
        $r = Get-BridgeResult $f
        Assert-Bridge ($r.Success -and $r.Messages.Count -eq 2) 'PowerShell messages should be collected separately.'
        Assert-Bridge (($r.Messages -join ',') -notmatch '192\.0\.2\.7') 'Messages should not reveal addresses.'
    }
    Test-BridgeCase 'Empty adapter list and message lists remain JSON arrays' {
        $f = New-FakeFixture; $f.State.Adapters = @()
        $json = Invoke-DesktopStatus -Backend $f.Backend
        Assert-Bridge ($json -match '"Adapters":\[\]' -and $json -match '"Messages":\[\]') 'Empty JSON collections must not become null.'
    }
}
finally {
    foreach ($name in $guardNames) {
        $path = 'Function:global:' + $name
        if ($savedFunctions.ContainsKey($name)) { Set-Item -LiteralPath $path -Value $savedFunctions[$name] }
        else { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    }
    $tripwireCount = $global:DesktopBridgeTripwires.Count
    Remove-Variable -Name DesktopBridgeTripwires -Scope Global -ErrorAction SilentlyContinue
}
Write-Host ('Bridge tests: ' + $script:Passed + ' passed, ' + $script:Failures.Count + ' failed; real system commands: ' + $tripwireCount + '.')
if ($script:Failures.Count -gt 0 -or $tripwireCount -gt 0) { throw ($script:Failures -join [Environment]::NewLine) }
