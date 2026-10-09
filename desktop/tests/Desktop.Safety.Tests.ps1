#Requires -Version 5.1
<#
Static source and embedded-resource checks only. This script does not import
the bridge/Core, invoke a network backend, launch the desktop EXE, or elevate.
Passing these checks is not a real-network/GUI integration test.
#>
[CmdletBinding()]
param(
    [string]$DesktopRoot = '',
    [string]$ExecutablePath = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = New-Object 'System.Collections.Generic.List[string]'
if ([string]::IsNullOrWhiteSpace($DesktopRoot)) { $DesktopRoot = Split-Path -Parent $PSScriptRoot }
$desktop = [IO.Path]::GetFullPath($DesktopRoot)
$repo = Split-Path -Parent $desktop
$corePath = Join-Path $repo 'scripts\TunForwarding.Core.psm1'
$buildPath = Join-Path $desktop 'Build.ps1'
$appPath = Join-Path $desktop 'App'
$xamlPath = Join-Path $appPath 'MainWindow.xaml'

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Text {
    param([string]$Text, [string]$Pattern, [string]$Message)
    Assert-Condition ($Text -match $Pattern) $Message
}
function Assert-NoText {
    param([string]$Text, [string]$Pattern, [string]$Message)
    Assert-Condition ($Text -notmatch $Pattern) $Message
}
function Test-SafetyCheck {
    param([string]$Name, [scriptblock]$Check)
    try {
        & $Check
        $script:Passed++
        Write-Host ('PASS: ' + $Name)
    } catch {
        $script:Failed.Add(($Name + ': ' + $_.Exception.Message))
        Write-Host ('FAIL: ' + $Name + ': ' + $_.Exception.Message)
    }
}
function Get-ParsedSource {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert-Condition (@($errors).Count -eq 0) ('Parser errors in ' + [IO.Path]::GetFileName($Path))
    return $ast
}
function Get-ResourceBytes {
    param([Reflection.Assembly]$Assembly, [string]$Name)
    $stream = $Assembly.GetManifestResourceStream($Name)
    Assert-Condition ($null -ne $stream) ('Missing embedded resource: ' + $Name)
    $buffer = New-Object IO.MemoryStream
    try { $stream.CopyTo($buffer); return ,$buffer.ToArray() }
    finally { $buffer.Dispose(); $stream.Dispose() }
}
function Get-BytesHash {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

# Source discovery only; never execute/import a discovered file.
Assert-Condition (Test-Path -LiteralPath $corePath -PathType Leaf) 'Core source missing.'
Assert-Condition (Test-Path -LiteralPath $buildPath -PathType Leaf) 'Desktop Build.ps1 missing.'
Assert-Condition (Test-Path -LiteralPath $appPath -PathType Container) 'Desktop App source missing.'
Assert-Condition (Test-Path -LiteralPath $xamlPath -PathType Leaf) 'Desktop window markup missing.'
$csFiles = @(Get-ChildItem -LiteralPath $appPath -Filter '*.cs' -Recurse -File | Sort-Object FullName)
$bridgeFiles = @(Get-ChildItem -LiteralPath $desktop -Recurse -File | Where-Object {
    $_.Name -match '(?i)bridge' -and $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '[\\/]tests[\\/]'
})
$manifests = @(Get-ChildItem -LiteralPath $desktop -Filter '*.manifest' -Recurse -File)
Assert-Condition ($csFiles.Count -gt 0) 'Desktop C# source missing.'
Assert-Condition ($bridgeFiles.Count -eq 1) 'Expected exactly one production PowerShell bridge source.'
Assert-Condition ($manifests.Count -eq 1) 'Expected exactly one application manifest.'
$bridgePath = $bridgeFiles[0].FullName
$bridge = Get-Content -LiteralPath $bridgePath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw
$cs = ($csFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$hostCs = Get-Content -LiteralPath (Join-Path $appPath 'EngineClient.cs') -Raw
$policyCs = Get-Content -LiteralPath (Join-Path $appPath 'UiPolicy.cs') -Raw
$manifest = Get-Content -LiteralPath $manifests[0].FullName -Raw
$xaml = Get-Content -LiteralPath $xamlPath -Raw
$bridgeAst = Get-ParsedSource $bridgePath

Test-SafetyCheck 'Core, bridge and build parse without execution' {
    $null = Get-ParsedSource $corePath
    $null = Get-ParsedSource $bridgePath
    $null = Get-ParsedSource $buildPath
}
Test-SafetyCheck 'Application manifest neither elevates nor requests UI access' {
    [xml]$xml = $manifest
    $nodes = @($xml.SelectNodes('//*[local-name()="requestedExecutionLevel"]'))
    Assert-Condition ($nodes.Count -eq 1) 'Manifest execution level is not unique.'
    Assert-Condition ($nodes[0].GetAttribute('level') -ceq 'asInvoker') 'Application must use asInvoker.'
    Assert-Condition ($nodes[0].GetAttribute('uiAccess') -ceq 'false') 'Application must not request uiAccess.'
}
Test-SafetyCheck 'Initial unknown-state UI does not offer a network action' {
    [xml]$markup = $xaml
    foreach ($name in @('ForwardingSwitch', 'FixButton', 'RestoreButton')) {
        $nodes = @($markup.SelectNodes('//*[local-name()="Button"]') | Where-Object {
            $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') -ceq $name
        })
        Assert-Condition ($nodes.Count -eq 1) ('Expected a unique action control: ' + $name)
        Assert-Condition ($nodes[0].GetAttribute('IsEnabled') -ceq 'False') ('Action must default to disabled: ' + $name)
    }
}
Test-SafetyCheck 'Forwarding UI starts unknown and identifies the property rather than TUN health' {
    Assert-Text $xaml 'x:Name="ForwardingValue"\s+Text="Unknown"' 'Initial Windows forwarding state must be unknown.'
    Assert-Text $xaml 'IPv4 packet forwarding' 'The property scope must be visible.'
    Assert-Text $xaml 'NOT TUN ON/OFF' 'The switch must not be presented as the Clash TUN switch.'
    Assert-Text $xaml 'not a TUN health test' 'State read-back must not imply recovered TUN traffic.'
}
Test-SafetyCheck 'Desktop code has no automatic UAC or process-killing recovery' {
    Assert-NoText ($cs + "`n" + $bridge) '(?i)\bRunAs\b|\bRunAsAdministrator\b|Verb\s*=\s*["'']runas["'']|\.Kill\s*\(|\.Stop\s*\(' 'Automatic elevation, pipeline cancellation or process killing is forbidden.'
}
Test-SafetyCheck 'Bridge has no direct network writes outside the audited Core' {
    $commands = @($bridgeAst.FindAll({ param($a) $a -is [Management.Automation.Language.CommandAst] }, $true))
    foreach ($command in $commands) {
        $name = [string]$command.GetCommandName()
        Assert-NoText $name '^(?i:Set-Net|Enable-Net|Disable-Net|Remove-Net|New-Net|netsh|Start-Process|Invoke-Expression|Invoke-WebRequest|Invoke-RestMethod)$|^(?i:Set-Net|Enable-Net|Disable-Net|Remove-Net|New-Net)' ('Forbidden bridge command: ' + $name)
    }
}
Test-SafetyCheck 'Application and bridge contain no download/upload/remoting APIs' {
    Assert-NoText ($cs + "`n" + $bridge) '(?i)\bHttpClient\b|\bWebClient\b|\bWebRequest\b|\bTcpClient\b|\bUdpClient\b|Download(File|String|Data)|Upload(File|String|Data)|WSManConnectionInfo|New-PSSession|Invoke-Command' 'No remote I/O or remote runspace is permitted.'
}
Test-SafetyCheck 'Local PowerShell host uses explicit runspace and error status' {
    Assert-Text $cs 'RunspaceFactory\s*\.\s*CreateRunspace\s*\(' 'Expected an explicit local runspace.'
    Assert-Text $cs '\bHadErrors\b|Streams\s*\.\s*Error' 'PowerShell errors must be inspected independently of returned output.'
    Assert-Text $cs 'ApartmentState\s*\.\s*STA' 'COM/PowerShell execution must explicitly use STA.'
}
Test-SafetyCheck 'Runtime scripts come from embedded assembly resources' {
    Assert-Text $cs 'GetManifestResourceStream\s*\(' 'Embedded scripts must be read from assembly resources.'
    Assert-NoText $cs '(?i)File\s*\.\s*ReadAll(Text|Bytes)\s*\([^;]*(?:Core|Bridge|\.psm?1)' 'Runtime must not read replaceable loose scripts.'
    Assert-Text $build '(?i)/resource:|-resource:|EmbeddedResource' 'Build must embed resources.'
    Assert-Text $build 'TunForwarding\.Core\.psm1' 'Build must use the audited Core.'
    Assert-Text $build '(?i)bridge' 'Build must embed the PowerShell bridge.'
    Assert-Text $build '(?i)win32manifest' 'Build must embed the application manifest.'
}
Test-SafetyCheck 'PowerShell autoload search is restricted to protected Windows system modules' {
    Assert-Text $hostCs 'SpecialFolder\s*\.\s*System' 'System module root must come from the Windows system folder.'
    Assert-Text $hostCs 'EnvironmentVariables\s*\.\s*Add\s*\(\s*new\s+SessionStateVariableEntry\s*\(\s*"PSModulePath"' 'The runspace must replace the inherited module search path.'
    # A UI language preference may use the user's data directory. Restrict the
    # executable-script resolver rather than forbidding harmless preferences.
    Assert-NoText $hostCs '(?i)UserProfile|MyDocuments|LocalApplicationData|CurrentDirectory|Assembly\s*\.\s*LoadFrom' 'Runtime must not resolve executable scripts/modules from user-writable locations.'
}
Test-SafetyCheck 'Target identity and prior state are passed as parameter data' {
    Assert-Text $cs '\.AddParameter\s*\(\s*"(?:ExpectedGuid|InterfaceGuid)"' 'The selected GUID must be passed through AddParameter.'
    Assert-Text $cs '\.AddParameter\s*\(\s*"ExpectedForwarding"' 'ExpectedForwarding must be passed through AddParameter.'
    Assert-Text $hostCs '\.AddParameter\s*\(\s*"ExpectedForwarding"\s*,\s*selected\.Forwarding\s*\)' 'The provider state must be passed verbatim rather than translated display text.'
    Assert-NoText $cs '(?is)\.AddScript\s*\([^;]*(?:\balias\b|\bInterfaceAlias\b|\bExpectedGuid\b|\bExpectedForwarding\b)' 'Adapter/confirmation data must not be interpolated into script text.'
    Assert-Text $bridge '\b(?:ExpectedGuid|InterfaceGuid)\b' 'Bridge must enforce the selected GUID.'
    Assert-Text $bridge '\bExpectedForwarding\b' 'Bridge must enforce the displayed prior state.'
}
Test-SafetyCheck 'Bridge only delegates fixed Core modes and exact confirmations' {
    Assert-Text $bridge 'Invoke-TunForwarding' 'Production changes must delegate to the audited Core.'
    Assert-Text $bridge 'NO-SHARING' 'Explicit topology confirmation must be supported.'
    Assert-Text $bridge 'RESTORE' 'Restore confirmation must be supported.'
    Assert-Text $bridge 'FIX' 'Fix confirmation must be supported.'
    Assert-NoText $bridge '(?is)\.Confirm\s*=\s*\{\s*(?:param\([^)]*\)\s*)?(?:return\s+)?\$true\s*\}' 'The bridge must not blanket-approve confirmations.'
}
Test-SafetyCheck 'Desktop exposes isolated demo/self-test entry points' {
    Assert-Text $cs '--render-demo' 'A deterministic UI rendering mode must not require real inspection.'
    Assert-Text $cs '--self-test' 'Self-test must use isolated state rather than a production backend.'
}
Test-SafetyCheck 'Refresh failures invalidate cached readiness rather than enabling old state' {
    Assert-Text $cs '(?s)catch\s*\(Exception\s+error\)\s*\{\s*status\s*=\s*null\s*;[^}]*ItemsSource\s*=\s*null' 'A failed refresh must clear the prior status and selection.'
    Assert-Text $cs '(?s)bool\s+ready\s*=\s*status\s*!=\s*null\s*&&\s*status\.Success' 'Rendering must not treat a failed inspection as ready.'
}
Test-SafetyCheck 'An active write blocks close and disables selection and refresh' {
    Assert-Text $cs '(?s)private\s+void\s+Closing\s*\([^)]*\)\s*\{\s*if\s*\(writing\)\s*\{\s*e\.Cancel\s*=\s*true' 'Window closing must refuse while a write is in progress.'
    Assert-Text $cs '(?s)private\s+void\s+SetBusy\s*\([^)]*\).*?"RefreshButton"\)\.IsEnabled\s*=\s*!value.*?"AdapterPicker"\)\.IsEnabled\s*=\s*!value' 'Busy operation must disable refresh and target changes.'
    Assert-Text $cs '(?s)private\s+async\s+Task\s+Act\s*\([^)]*\)\s*\{\s*if\s*\(busy\s*\|\|\s*manualReview\)\s*return' 'Busy or failed recovery must refuse repeated action entry.'
}
Test-SafetyCheck 'Operation uses captured identity and flags rollback failure for local review' {
    Assert-Text $cs '(?s)var\s+request\s*=\s*new\s+AdapterStatus\s*\{[^}]*InterfaceGuid\s*=\s*selected\.InterfaceGuid[^}]*InterfaceAlias\s*=\s*selected\.InterfaceAlias[^}]*Forwarding\s*=\s*selected\.Forwarding' 'Confirmed request identity/state must be captured before the worker runs.'
    Assert-Text $cs 'manualReview\s*=\s*action\.RollbackFailed' 'Rollback failure must block later writes in this session.'
}
Test-SafetyCheck 'Dialog starts unconfirmed and requires exact words with a cleanup-only exception' {
    # Translation format strings can contain braces inside the initializer.
    Assert-Text $cs '(?s)var\s+confirm\s*=\s*new\s+Button\s*\{[^;]*IsEnabled\s*=\s*false' 'Confirmation must not start enabled.'
    Assert-Text $policyCs 'actionWord\s*!=\s*mode\.ToUpperInvariant\s*\(\s*\)' 'Action confirmation must be exact and case-sensitive.'
    Assert-Text $policyCs 'cleanup\s*&&\s*mode\s*==\s*"Restore"' 'The topology-free cleanup exception must be Restore only.'
    Assert-Text $policyCs 'tunOff\s*&&\s*noSharing\s*&&\s*topologyWord\s*==\s*"NO-SHARING"' 'Network-write confirmation needs both acknowledgments and NO-SHARING.'
    Assert-NoText $policyCs '\b(?:L|Localization)\s*\.\s*(?:T|F|Select)\s*\(' 'Policy must compare raw provider states and confirmation words, never translations.'
}
Test-SafetyCheck 'Build has no package download or automatic publication' {
    Assert-NoText $build '(?i)Invoke-WebRequest|Invoke-RestMethod|Download(File|String|Data)|\bnuget\b|\bdotnet\s+restore\b|\bgh\s+(release|repo|pr)\b|\bgit\s+push\b|Verb\s+RunAs' 'Build must remain local and must not publish or elevate.'
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    Write-Host 'NOT TESTED: EXE embedded resources (supply -ExecutablePath in Windows PowerShell 5.1).'
} else {
    Assert-Condition ($PSVersionTable.PSVersion.Major -eq 5) 'Reflection-only EXE checks require Windows PowerShell 5.1.'
    $exePath = [IO.Path]::GetFullPath($ExecutablePath)
    Assert-Condition (Test-Path -LiteralPath $exePath -PathType Leaf) 'Desktop EXE missing.'
    # Reflection-only loading reads metadata/resources; it never invokes Main,
    # a static constructor, the PowerShell host, or the network backend.
    $assembly = [Reflection.Assembly]::ReflectionOnlyLoadFrom($exePath)
    $resources = @($assembly.GetManifestResourceNames())
    Test-SafetyCheck 'Embedded Core bytes exactly match the audited source' {
        $names = @($resources | Where-Object { $_ -match '(?i)core' })
        Assert-Condition ($names.Count -eq 1) 'Embedded Core resource must be unique.'
        Assert-Condition ((Get-BytesHash (Get-ResourceBytes $assembly $names[0])) -ceq (Get-BytesHash ([IO.File]::ReadAllBytes($corePath)))) 'Embedded Core differs from source.'
    }
    Test-SafetyCheck 'Embedded bridge bytes exactly match the reviewed source' {
        $names = @($resources | Where-Object { $_ -match '(?i)bridge' })
        Assert-Condition ($names.Count -eq 1) 'Embedded bridge resource must be unique.'
        Assert-Condition ((Get-BytesHash (Get-ResourceBytes $assembly $names[0])) -ceq (Get-BytesHash ([IO.File]::ReadAllBytes($bridgePath)))) 'Embedded bridge differs from source.'
    }
    Test-SafetyCheck 'Embedded window bytes exactly match the reviewed safety UI' {
        $names = @($resources | Where-Object { $_ -match '(?i)window' })
        Assert-Condition ($names.Count -eq 1) 'Embedded window resource must be unique.'
        Assert-Condition ((Get-BytesHash (Get-ResourceBytes $assembly $names[0])) -ceq (Get-BytesHash ([IO.File]::ReadAllBytes($xamlPath)))) 'Embedded window differs from reviewed markup.'
    }
    Test-SafetyCheck 'License and local-preview notice are present inside the single EXE' {
        foreach ($entry in @(
            @{ Pattern = '(?i)license'; Path = (Join-Path $repo 'LICENSE') },
            @{ Pattern = '(?i)notice'; Path = (Join-Path $desktop 'NOTICE.md') }
        )) {
            $names = @($resources | Where-Object { $_ -match $entry.Pattern })
            Assert-Condition ($names.Count -eq 1) 'Expected a unique embedded license/notice resource.'
            Assert-Condition ((Get-BytesHash (Get-ResourceBytes $assembly $names[0])) -ceq (Get-BytesHash ([IO.File]::ReadAllBytes($entry.Path)))) 'Embedded license/notice differs from source.'
        }
    }
    Test-SafetyCheck 'Seven embedded language resources exactly match the reviewed JSON files' {
        foreach ($code in @('en', 'ja', 'zh', 'ms', 'it', 'de', 'ru')) {
            $name = 'TunAssist.Locale.' + $code
            $names = @($resources | Where-Object { $_ -ceq $name })
            Assert-Condition ($names.Count -eq 1) ('Missing or duplicate language resource: ' + $code)
            $path = Join-Path $desktop ('Locales/' + $code + '.json')
            Assert-Condition (Test-Path -LiteralPath $path -PathType Leaf) ('Language JSON missing: ' + $code)
            Assert-Condition ((Get-BytesHash (Get-ResourceBytes $assembly $name)) -ceq (Get-BytesHash ([IO.File]::ReadAllBytes($path)))) ('Embedded language differs from source: ' + $code)
        }
    }
    Test-SafetyCheck 'EXE references installed Windows PowerShell rather than PowerShell 7' {
        $references = @($assembly.GetReferencedAssemblies() | Where-Object Name -eq 'System.Management.Automation')
        Assert-Condition ($references.Count -eq 1) 'Expected one System.Management.Automation reference.'
        Assert-Condition ($references[0].Version -eq [version]'3.0.0.0') 'Expected Windows PowerShell 5.1 assembly identity.'
    }
    Test-SafetyCheck 'Built EXE contains its asInvoker manifest' {
        $imageText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($exePath))
        Assert-Text $imageText 'requestedExecutionLevel\s+level="asInvoker"\s+uiAccess="false"' 'Built EXE lacks the intended asInvoker manifest.'
    }
}

Write-Host ('Static safety checks: ' + $script:Passed + ' passed; ' + $script:Failed.Count + ' failed; no application/network execution.')
if ($script:Failed.Count -gt 0) { throw ($script:Failed -join "`n") }
