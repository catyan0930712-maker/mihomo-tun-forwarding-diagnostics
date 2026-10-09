#Requires -Version 5.1
# Dot-sourcing defines the bridge only. No adapter inspection or mutation occurs.
Set-StrictMode -Version 2.0
$script:DesktopCoreModule = $null
$script:DesktopEngineFolder = $PSScriptRoot

function Initialize-DesktopEngine {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CoreScriptText)
    if ([string]::IsNullOrWhiteSpace($CoreScriptText)) { throw 'Embedded safety engine is empty.' }
    # This is the application's trusted embedded resource, never a user input.
    $script:DesktopCoreModule = New-Module -Name 'MihomoTunDesktopCore' -ScriptBlock ([scriptblock]::Create($CoreScriptText))
}

function Get-DesktopEngineModule {
    if ($null -eq $script:DesktopCoreModule) {
        if ([string]::IsNullOrWhiteSpace($script:DesktopEngineFolder)) { throw 'Embedded safety engine has not been initialized.' }
        $path = Join-Path $script:DesktopEngineFolder 'TunForwarding.Core.psm1'
        Initialize-DesktopEngine -CoreScriptText ([IO.File]::ReadAllText($path))
    }
    return $script:DesktopCoreModule
}

function Protect-DesktopText {
    param([object]$Text)
    $value = [string]$Text
    $value = [regex]::Replace($value, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '[address redacted]')
    $value = [regex]::Replace($value, '(?i)(?<![a-f0-9:])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:.]*(?:%[a-z0-9_.-]+)?', '[address redacted]')
    if ($value.Length -gt 4096) { $value = $value.Substring(0, 4096) + ' [truncated]' }
    return $value
}

function Assert-DesktopBackend {
    param([hashtable]$Backend)
    foreach ($key in @('IsAdministrator', 'GetAdapters', 'GetRoutes', 'GetIpv4', 'GetSafetyState', 'SetForwarding',
        'Confirm', 'GetMachineId', 'ReadSnapshot', 'WriteSnapshot', 'DeleteSnapshot', 'Now')) {
        if (-not $Backend.ContainsKey($key) -or $Backend[$key] -isnot [scriptblock]) { throw ('Missing backend operation: ' + $key) }
    }
    if ($Backend.ContainsKey('BeginOperation') -or $Backend.ContainsKey('EndOperation')) {
        if (-not $Backend.ContainsKey('BeginOperation') -or -not $Backend.ContainsKey('EndOperation') -or
            $Backend.BeginOperation -isnot [scriptblock] -or $Backend.EndOperation -isnot [scriptblock]) {
            throw 'Backend lock operations must be a complete scriptblock pair.'
        }
    }
}

function Invoke-DesktopCaptured {
    param([scriptblock]$Body, [System.Collections.Generic.List[string]]$Messages)
    $values = New-Object 'System.Collections.Generic.List[object]'
    $state = @{ Error = $null }
    try {
        & $Body *>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) {
                $state.Error = Protect-DesktopText $_.Exception.Message
            }
            elseif ($_ -is [Management.Automation.InformationRecord]) {
                $Messages.Add((Protect-DesktopText $_.MessageData))
            }
            elseif ($_ -is [Management.Automation.WarningRecord] -or
                $_ -is [Management.Automation.VerboseRecord] -or $_ -is [Management.Automation.DebugRecord]) {
                $Messages.Add((Protect-DesktopText $_.Message))
            }
            else { $values.Add($_) }
        }
    }
    catch { $state.Error = Protect-DesktopText $_.Exception.Message }
    return [pscustomobject]@{ Values = $values.ToArray(); Error = $state.Error }
}

function Invoke-DesktopStatus {
    [CmdletBinding()]
    param([hashtable]$Backend = $null)
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $response = [ordered]@{
        SchemaVersion = 1; Success = $false; Message = 'Status unavailable.'
        IsAdministrator = $false; CheckedAtUtc = [datetime]::UtcNow.ToString('o')
        Safety = [pscustomobject]@{ Known = $false; Risks = @() }
        Adapters = @(); Messages = @()
    }
    try {
        $core = Get-DesktopEngineModule
        if ($null -eq $Backend) { $Backend = & $core { New-WindowsBackend } }
        Assert-DesktopBackend $Backend
        $captured = Invoke-DesktopCaptured -Messages $messages -Body {
            $administrator = $false
            $administratorKnown = $true
            $administratorError = ''
            try { $administrator = (& $Backend.IsAdministrator) -eq $true }
            catch {
                $administratorKnown = $false
                $administratorError = Protect-DesktopText $_.Exception.Message
                $messages.Add(('Administrator status could not be determined: ' + $administratorError))
            }
            $adapters = @(& $Backend.GetAdapters)
            $routes = @()
            $routesKnown = $true
            $routesError = ''
            try { $routes = @(& $Backend.GetRoutes) }
            catch {
                $routesKnown = $false
                $routesError = Protect-DesktopText $_.Exception.Message
                $messages.Add(('IPv4 default-route inspection is unavailable: ' + $routesError))
            }
            $safety = [pscustomobject]@{ Known = $false; Risks = @('Sharing/routing inspection is unavailable.') }
            try {
                $inspected = & $Backend.GetSafetyState
                $safety = [pscustomobject]@{
                    Known = ($inspected.Known -eq $true)
                    Risks = @($inspected.Risks | ForEach-Object { Protect-DesktopText $_ })
                }
                if (-not $safety.Known) {
                    foreach ($risk in @($safety.Risks)) {
                        $messages.Add(('Sharing/routing inspection finding: ' + $risk))
                    }
                    if (@($safety.Risks | Where-Object { $_ -ceq 'ICS inspection unavailable' }).Count -gt 0) {
                        $messages.Add('ICS inspection did not complete. The safety engine did not return an exception detail; this does not establish that sharing is active.')
                    }
                }
            }
            catch {
                $safetyError = Protect-DesktopText $_.Exception.Message
                $safety = [pscustomobject]@{ Known = $false; Risks = @(('Sharing/routing inspection is unavailable: ' + $safetyError)) }
                $messages.Add(('Sharing/routing inspection failed; network writes remain blocked: ' + $safetyError))
            }
            $machine = $null
            $machineKnown = $false
            $machineError = ''
            if ($administrator) {
                try {
                    $machine = [string](& $Backend.GetMachineId)
                    $machineKnown = -not [string]::IsNullOrWhiteSpace($machine)
                    if (-not $machineKnown) { $machineError = 'The machine identifier was empty.' }
                }
                catch {
                    $machineError = Protect-DesktopText $_.Exception.Message
                    $messages.Add(('Snapshot provenance could not be inspected: ' + $machineError))
                }
            }
            $rows = @(foreach ($adapter in $adapters) {
                $guid = ''
                $physical = $false
                $eligibility = ''
                try {
                    $guid = & $core { param($a) ConvertTo-AdapterGuid $a.InterfaceGuid } $adapter
                    & $core { param($a) Assert-PhysicalAdapter $a $false } $adapter
                    $physical = $true
                    $eligibility = 'Positively identified physical hardware.'
                }
                catch { $eligibility = Protect-DesktopText $_.Exception.Message }
                $index = 0
                try { $index = [int]$adapter.ifIndex } catch { }
                $forwarding = 'Unknown'
                $forwardingError = ''
                try { $forwarding = & $core { param($b, $a) Get-ForwardingValue $b $a } $Backend $adapter }
                catch {
                    $forwardingError = Protect-DesktopText $_.Exception.Message
                    $messages.Add((Protect-DesktopText ('IPv4 forwarding inspection failed for ' + [string]$adapter.Name + ': ' + $forwardingError)))
                }
                $snapshot = [pscustomobject]@{
                    State = 'Unknown'; Known = $false; Present = $null; Valid = $null
                    Reason = 'AdministratorRequired'
                    Message = 'Protected recovery snapshots were not inspected because this is not an administrator session. Their presence and validity are unknown.'
                }
                if (-not $administratorKnown) {
                    $snapshot.Reason = 'AdministratorStatusUnavailable'
                    $snapshot.Message = 'Administrator status could not be determined. Protected snapshots were not inspected: ' + $administratorError
                }
                if ($administrator -and $machineKnown -and $guid) {
                    try {
                        $record = & $Backend.ReadSnapshot $guid
                        if ($null -eq $record) {
                            $snapshot = [pscustomobject]@{
                                State = 'Absent'; Known = $true; Present = $false; Valid = $null
                                Reason = 'NoSnapshot'
                                Message = 'No recovery snapshot.'
                            }
                        }
                        else {
                            try {
                                & $core { param($r, $g, $m, $now) Assert-Snapshot $r $g $m $now } $record $guid $machine (& $Backend.Now)
                                $snapshot = [pscustomobject]@{
                                    State = 'Valid'; Known = $true; Present = $true; Valid = $true
                                    Reason = 'Validated'
                                    Message = 'Snapshot identity, schema and age validated.'
                                }
                            }
                            catch {
                                $snapshot = [pscustomobject]@{
                                    State = 'Invalid'; Known = $true; Present = $true; Valid = $false
                                    Reason = 'ValidationFailed'
                                    Message = (Protect-DesktopText $_.Exception.Message)
                                }
                            }
                        }
                    }
                    catch {
                        $snapshot.Reason = 'ReadFailed'
                        $snapshot.Message = 'Protected snapshot could not be read. Presence and validity are unknown: ' + (Protect-DesktopText $_.Exception.Message)
                    }
                }
                elseif ($administrator) {
                    if (-not $machineKnown) {
                        $snapshot.Reason = 'MachineIdentityUnavailable'
                        $snapshot.Message = 'Snapshot machine provenance could not be verified. Protected snapshots were not inspected: ' + $machineError
                    }
                    else {
                        $snapshot.Reason = 'AdapterIdentityUnavailable'
                        $snapshot.Message = 'Snapshot adapter identity could not be verified. Protected snapshots were not inspected: ' + $eligibility
                    }
                }
                $hasRoute = $routesKnown -and @($routes | Where-Object { $_.InterfaceIndex -eq $index }).Count -gt 0
                $topologySafe = $safety.Known -and @($safety.Risks).Count -eq 0
                [pscustomobject]@{
                    InterfaceGuid = [string]$guid; InterfaceAlias = [string]$adapter.Name
                    Description = (Protect-DesktopText $adapter.InterfaceDescription)
                    InterfaceIndex = $index; Status = [string]$adapter.Status
                    PhysicalEligible = $physical; EligibilityMessage = $eligibility
                    HasDefaultRoute = [bool]$hasRoute; DefaultRouteKnown = $routesKnown; DefaultRouteReadError = $routesError
                    Forwarding = $forwarding; ForwardingReadError = $forwardingError; Snapshot = $snapshot
                    CanFix = [bool]($administrator -and $physical -and [string]$adapter.Status -ceq 'Up' -and
                        $hasRoute -and $forwarding -ceq 'Enabled' -and $snapshot.State -ceq 'Absent' -and $topologySafe)
                    CanRestore = [bool]($administrator -and $physical -and $snapshot.State -ceq 'Valid' -and
                        ($forwarding -ceq 'Enabled' -or ($forwarding -ceq 'Disabled' -and $topologySafe)))
                }
            })
            [pscustomobject]@{ IsAdministrator = $administrator; Safety = $safety; Adapters = @($rows) }
        }
        if ($captured.Error) { throw $captured.Error }
        if (@($captured.Values).Count -ne 1) { throw 'Status backend returned unexpected output.' }
        $status = $captured.Values[0]
        $response.Success = $true
        $response.Message = 'Read-only status refreshed. No network settings were changed.'
        $response.IsAdministrator = $status.IsAdministrator
        $response.Safety = $status.Safety
        $response.Adapters = @($status.Adapters)
    }
    catch { $response.Message = Protect-DesktopText $_.Exception.Message }
    $response.Messages = @($messages.ToArray())
    return ($response | ConvertTo-Json -Depth 8 -Compress)
}

function New-DesktopBoundBackend {
    param([hashtable]$Backend, [object]$Core, [string]$Guid, [string]$Alias,
        [string]$Expected, [string]$Mode, [bool]$NoSharing, [bool]$Confirmed)
    $original = $Backend
    $context = @{ MutationAttempted = $false }
    $normalize = {
        param($Value)
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse([string]$Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) { throw 'Invalid adapter GUID.' }
        return $parsed.ToString('D').ToLowerInvariant()
    }
    $resolve = {
        $all = @(& $original.GetAdapters)
        $guidMatches = @(foreach ($item in $all) {
            try { if ((& $normalize $item.InterfaceGuid) -ceq $Guid) { $item } } catch { }
        })
        $aliasMatches = @($all | Where-Object { [string]$_.Name -ceq $Alias })
        if ($guidMatches.Count -ne 1 -or $aliasMatches.Count -ne 1 -or [string]$guidMatches[0].Name -cne $Alias -or
            (& $normalize $aliasMatches[0].InterfaceGuid) -cne $Guid) { throw 'Selected adapter identity or exact name changed. Refresh and confirm again.' }
        & $Core { param($a) Assert-PhysicalAdapter $a $false } $guidMatches[0]
        return $guidMatches[0]
    }.GetNewClosure()
    $read = {
        param($Adapter)
        if ((& $normalize $Adapter.InterfaceGuid) -cne $Guid -or [string]$Adapter.Name -cne $Alias) { throw 'An unconfirmed interface was requested.' }
        $live = & $resolve
        $rows = @(& $original.GetIpv4 $live)
        if ($rows.Count -ne 1) { throw 'IPv4 interface did not resolve uniquely.' }
        $value = [string]$rows[0].Forwarding
        if ($value -cnotin @('Enabled', 'Disabled')) { throw 'Unexpected IPv4 forwarding state.' }
        if (-not $context.MutationAttempted -and $value -cne $Expected) { throw 'Forwarding changed since the displayed status. Refresh and confirm again.' }
        return $rows[0]
    }.GetNewClosure()
    $bound = $Backend.Clone()
    $bound.GetAdapters = { return (& $resolve) }.GetNewClosure()
    $bound.GetIpv4 = { param($a) return (& $read $a) }.GetNewClosure()
    $bound.Confirm = {
        param($Action)
        if ($Action -ceq 'NO-SHARING') { return $NoSharing }
        if ($Action -ceq $Mode.ToUpperInvariant()) { return $Confirmed }
        return $false
    }.GetNewClosure()
    $bound.SetForwarding = {
        param($Adapter, $Target)
        if ((& $normalize $Adapter.InterfaceGuid) -cne $Guid -or [string]$Adapter.Name -cne $Alias) { throw 'An unconfirmed interface write was requested.' }
        $live = & $resolve
        if (-not $context.MutationAttempted) {
            $null = & $read $live
            if ($Mode -ceq 'Fix') {
                & $Core { param($a) Assert-PhysicalAdapter $a $true } $live
                if (@(& $original.GetRoutes | Where-Object { $_.InterfaceIndex -eq $live.ifIndex }).Count -eq 0) { throw 'Selected physical adapter has no IPv4 default route.' }
            }
            & $Core { param($b) Assert-SafeTopology $b } $original
        }
        $context.MutationAttempted = $true
        & $original.SetForwarding $live $Target
    }.GetNewClosure()
    $bound.ReadSnapshot = {
        param($RequestedGuid)
        if ((& $normalize $RequestedGuid) -cne $Guid) { throw 'An unconfirmed snapshot was requested.' }
        & $original.ReadSnapshot $Guid
    }.GetNewClosure()
    $bound.WriteSnapshot = {
        param($RequestedGuid, $Record)
        if ((& $normalize $RequestedGuid) -cne $Guid -or (& $normalize $Record.InterfaceGuid) -cne $Guid) { throw 'An unconfirmed snapshot write was requested.' }
        $live = & $resolve
        $null = & $read $live
        & $original.WriteSnapshot $Guid $Record
    }.GetNewClosure()
    $bound.DeleteSnapshot = {
        param($RequestedGuid)
        if ((& $normalize $RequestedGuid) -cne $Guid) { throw 'An unconfirmed snapshot deletion was requested.' }
        $live = & $resolve
        $current = @(& $original.GetIpv4 $live)
        if ($current.Count -ne 1 -or [string]$current[0].Forwarding -cne 'Enabled') { throw 'Original forwarding could not be reverified; snapshot retained.' }
        & $original.DeleteSnapshot $Guid
    }.GetNewClosure()
    return $bound
}

function Invoke-DesktopAction {
    [CmdletBinding()]
    param([string]$Mode, [string]$InterfaceGuid, [string]$InterfaceAlias, [string]$ExpectedForwarding,
        [object]$NoSharingConfirmed = $false, [object]$ActionConfirmed = $false, [hashtable]$Backend = $null)
    $messages = New-Object 'System.Collections.Generic.List[string]'
    $response = [ordered]@{ SchemaVersion = 1; Success = $false; Message = 'Operation refused.'; Messages = @(); RollbackFailed = $false }
    try {
        if ($Mode -cnotin @('Fix', 'Restore')) { throw 'Only Fix or Restore is allowed.' }
        if ($ExpectedForwarding -cnotin @('Enabled', 'Disabled')) { throw 'A known displayed forwarding state is required.' }
        if ([string]::IsNullOrWhiteSpace($InterfaceAlias)) { throw 'An exact adapter name is required.' }
        if ($ActionConfirmed -isnot [bool] -or $ActionConfirmed -ne $true) { throw 'The exact action must be explicitly confirmed.' }
        if ($NoSharingConfirmed -isnot [bool]) { throw 'Sharing confirmation must be a Boolean value.' }
        $core = Get-DesktopEngineModule
        $guid = & $core { param($g) ConvertTo-AdapterGuid $g } $InterfaceGuid
        if ($null -eq $Backend) { $Backend = & $core { New-WindowsBackend } }
        Assert-DesktopBackend $Backend
        $captured = Invoke-DesktopCaptured -Messages $messages -Body {
            if (-not (& $Backend.IsAdministrator)) { throw 'Run this application as administrator to use Fix or Restore. Automatic elevation is disabled.' }
            $bound = New-DesktopBoundBackend -Backend $Backend -Core $core -Guid $guid -Alias $InterfaceAlias -Expected $ExpectedForwarding -Mode $Mode -NoSharing $NoSharingConfirmed -Confirmed $ActionConfirmed
            & $core { param($m, $name, $b) Invoke-TunForwarding -Mode $m -InterfaceAlias $name -Backend $b } $Mode $InterfaceAlias $bound
        }
        if ($captured.Error) { throw $captured.Error }
        if (@($captured.Values).Count -ne 1 -or $null -eq $captured.Values[0].PSObject.Properties['Message']) { throw 'Safety engine returned unexpected output.' }
        $response.Success = $true
        $response.Message = Protect-DesktopText $captured.Values[0].Message
    }
    catch {
        $response.Message = Protect-DesktopText $_.Exception.Message
        $response.RollbackFailed = $response.Message -cmatch 'ROLLBACK FAILED'
    }
    $response.Messages = @($messages.ToArray())
    return ($response | ConvertTo-Json -Depth 5 -Compress)
}
