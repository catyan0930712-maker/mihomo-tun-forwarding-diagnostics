#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '', [string]$IntermediateDirectory = '')
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Build with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.' }
if ([Environment]::Is64BitProcess -ne $true) { throw 'Use 64-bit Windows PowerShell.' }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot '../outputs' }
if ([string]::IsNullOrWhiteSpace($IntermediateDirectory)) { $IntermediateDirectory = Join-Path $PSScriptRoot '../build/desktop' }
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = [IO.Path]::GetFullPath($IntermediateDirectory)
$null = New-Item -ItemType Directory -Path $outputRoot -Force
$null = New-Item -ItemType Directory -Path $buildRoot -Force
$framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$automation = [System.Management.Automation.PSObject].Assembly
if ($automation.GetName().Version.Major -ne 3) { throw 'Expected the Windows PowerShell 5.1 automation assembly.' }
$resources = @{
    'TunAssist.Window' = Join-Path $PSScriptRoot 'App/MainWindow.xaml'
    'TunAssist.Core' = Join-Path $PSScriptRoot 'Engine/TunForwarding.Core.psm1'
    'TunAssist.Bridge' = Join-Path $PSScriptRoot 'Engine/DesktopBridge.ps1'
    'TunAssist.License' = Join-Path $PSScriptRoot '../LICENSE'
    'TunAssist.Notice' = Join-Path $PSScriptRoot 'NOTICE.md'
    'TunAssist.AppManifest' = Join-Path $PSScriptRoot 'app.manifest'
    'TunAssist.Icon' = Join-Path $PSScriptRoot 'Assets/TunAssist.png'
}
foreach ($language in @('en', 'ja', 'zh', 'ms', 'it', 'de', 'ru')) {
    $resources['TunAssist.Locale.' + $language] = Join-Path $PSScriptRoot ('Locales/' + $language + '.json')
}
foreach ($resource in $resources.Values) { if (-not (Test-Path -LiteralPath $resource -PathType Leaf)) { throw "Missing build resource: $resource" } }
$originalCore = Join-Path $PSScriptRoot '../scripts/TunForwarding.Core.psm1'
if ((Get-FileHash -LiteralPath $originalCore).Hash -cne (Get-FileHash -LiteralPath $resources['TunAssist.Core']).Hash) { throw 'Desktop core differs from the reviewed source core.' }
$iconPath = Join-Path $PSScriptRoot 'Assets/TunAssist.ico'
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Missing application icon.' }
$exePath = Join-Path $outputRoot 'TunAssist.exe'
$arguments = New-Object Collections.Generic.List[string]
$arguments.Add('/nologo'); $arguments.Add('/target:winexe'); $arguments.Add('/platform:x64'); $arguments.Add('/optimize+'); $arguments.Add('/codepage:65001'); $arguments.Add('/utf8output')
$arguments.Add('/out:"' + $exePath + '"')
$arguments.Add('/win32manifest:"' + (Join-Path $PSScriptRoot 'app.manifest') + '"')
$arguments.Add('/win32icon:"' + $iconPath + '"')
foreach ($reference in @('System.dll','System.Core.dll','System.Xaml.dll','System.Web.Extensions.dll','WPF/WindowsBase.dll','WPF/PresentationCore.dll','WPF/PresentationFramework.dll')) {
    $arguments.Add('/reference:"' + (Join-Path $framework $reference) + '"')
}
$arguments.Add('/reference:"' + $automation.Location + '"')
foreach ($name in ($resources.Keys | Sort-Object)) { $arguments.Add('/resource:"' + $resources[$name] + '",' + $name) }
foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'App') -Filter '*.cs' -File | Sort-Object Name)) { $arguments.Add('"' + $file.FullName + '"') }
$responsePath = Join-Path $buildRoot 'compile.rsp'
[IO.File]::WriteAllLines($responsePath, $arguments.ToArray(), (New-Object Text.UTF8Encoding($true)))
& $compiler ('@' + $responsePath)
if ($LASTEXITCODE -ne 0) { throw ('C# compilation failed: ' + $LASTEXITCODE) }
$package = Get-Item -LiteralPath $exePath
Write-Output ('Built single EXE: ' + $package.FullName)
Write-Output ('Bytes: ' + $package.Length)
Write-Output ('SHA256: ' + (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash.ToLowerInvariant())
