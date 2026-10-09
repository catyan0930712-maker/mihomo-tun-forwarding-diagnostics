#Requires -Version 5.1
<#
Pure UTF-8 JSON resource checks. No backend, application, PowerShell host,
network provider or system command is invoked. These checks validate resource
structure and safety words, not the linguistic quality of every translation.
#>
[CmdletBinding()]
param([string]$DesktopRoot = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DesktopRoot)) { $DesktopRoot = Split-Path -Parent $PSScriptRoot }
$localeRoot = Join-Path ([IO.Path]::GetFullPath($DesktopRoot)) 'Locales'
$codes = @('en', 'ja', 'zh', 'ms', 'it', 'de', 'ru')
$script:Passed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-Locale {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-LocaleCase {
    param([string]$Name, [scriptblock]$Check)
    try {
        & $Check
        $script:Passed++
        Write-Host ('PASS ' + $Name)
    }
    catch {
        $script:Failures.Add(($Name + ': ' + $_.Exception.Message))
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}
function Read-LocaleResource {
    param([string]$Path)
    Assert-Locale (Test-Path -LiteralPath $Path -PathType Leaf) ('Missing language resource: ' + [IO.Path]::GetFileName($Path))
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $raw = $utf8.GetString([IO.File]::ReadAllBytes($Path)).TrimStart([char]0xFEFF)
    $data = ConvertFrom-Json -InputObject $raw
    Assert-Locale ($null -ne $data -and $data -is [pscustomobject]) 'Expected a flat JSON object.'
    $properties = @($data.PSObject.Properties)
    Assert-Locale ($properties.Count -gt 0) 'Language resource must not be empty.'
    # Every flat string-to-string property has exactly two JSON string tokens.
    # Counting them also rejects a repeated key hidden by JSON deserialization.
    $strings = [regex]::Matches($raw, '"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"')
    Assert-Locale ($strings.Count -eq 2 * $properties.Count) 'Expected unique keys with string values only.'
    $result = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($property in $properties) {
        Assert-Locale (-not [string]::IsNullOrWhiteSpace($property.Name)) 'Resource key must not be empty.'
        Assert-Locale ($property.Value -is [string]) ('Non-string value: ' + $property.Name)
        Assert-Locale (-not [string]::IsNullOrWhiteSpace($property.Value)) ('Empty translation: ' + $property.Name)
        $result.Add($property.Name, [string]$property.Value)
    }
    return ,$result
}
function Get-FormatTokens {
    param([string]$Value)
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $Value.Length; $i++) {
        if ($Value[$i] -eq '{') {
            if ($i + 1 -lt $Value.Length -and $Value[$i + 1] -eq '{') { $i++; continue }
            $end = $Value.IndexOf('}', $i + 1)
            Assert-Locale ($end -gt $i) 'Unclosed format placeholder.'
            $token = $Value.Substring($i, $end - $i + 1)
            Assert-Locale ($token -match '^\{\d+(?:,-?\d+)?(?::[^{}]*)?\}$') ('Invalid format placeholder: ' + $token)
            $tokens.Add($token)
            $i = $end
        }
        elseif ($Value[$i] -eq '}') {
            Assert-Locale ($i + 1 -lt $Value.Length -and $Value[$i + 1] -eq '}') 'Unescaped closing format brace.'
            $i++
        }
    }
    return ,$tokens.ToArray()
}

$resources = @{}
foreach ($code in $codes) {
    Test-LocaleCase ($code + ': strict UTF-8, unique flat keys and nonempty string translations') {
        $resources[$code] = Read-LocaleResource (Join-Path $localeRoot ($code + '.json'))
    }
}
Assert-Locale ($resources.ContainsKey('en')) 'English baseline could not be read; resource comparisons cannot proceed.'
$baseline = $resources['en']
$baselineKeys = @($baseline.Keys | Sort-Object -CaseSensitive)
foreach ($code in $codes) {
    Test-LocaleCase ($code + ': exact English key set') {
        Assert-Locale ($resources.ContainsKey($code)) 'Language resource could not be read.'
        $locale = $resources[$code]
        Assert-Locale ($locale.Count -eq $baseline.Count) 'Key count differs from English.'
        foreach ($key in $baselineKeys) { Assert-Locale ($locale.ContainsKey($key)) ('Missing exact key: ' + $key) }
    }
    Test-LocaleCase ($code + ': composite format placeholders match, including repeated arguments') {
        Assert-Locale ($resources.ContainsKey($code)) 'Language resource could not be read.'
        $locale = $resources[$code]
        foreach ($key in $baselineKeys) {
            Assert-Locale ($locale.ContainsKey($key)) ('Missing exact key: ' + $key)
            $sourceTokens = @(Get-FormatTokens $baseline[$key] | ForEach-Object { $_ } | Sort-Object -CaseSensitive)
            $targetTokens = @(Get-FormatTokens $locale[$key] | ForEach-Object { $_ } | Sort-Object -CaseSensitive)
            Assert-Locale (($sourceTokens -join [char]0x1F) -ceq ($targetTokens -join [char]0x1F)) ('Format tokens differ: ' + $key)
        }
    }
    Test-LocaleCase ($code + ': full confirmation and guide sentences preserve literal safety words') {
        Assert-Locale ($resources.ContainsKey($code)) 'Language resource could not be read.'
        $locale = $resources[$code]
        foreach ($key in $baselineKeys) {
            Assert-Locale ($locale.ContainsKey($key)) ('Missing exact key: ' + $key)
            # Only demand tokens that really occur in the English sentence.
            # Generic "Confirm {0}" / "Type {0}" use a runtime raw mode and
            # are checked above for {0}, rather than inventing a literal FIX.
            foreach ($word in @('FIX', 'RESTORE', 'NO-SHARING')) {
                # A hyphen may separate a German compound such as
                # "RESTORE-Bestaetigung" while leaving RESTORE unchanged.
                $pattern = '(?<![A-Za-z0-9_])' + [regex]::Escape($word) + '(?![A-Za-z0-9_])'
                $expected = [regex]::Matches($baseline[$key], $pattern).Count
                if ($expected -gt 0) {
                    Assert-Locale ([regex]::Matches($locale[$key], $pattern).Count -ge $expected) ('Literal ' + $word + ' was translated or omitted: ' + $key)
                }
            }
        }
    }
}
Write-Host ('Localization resource checks: ' + $script:Passed + ' passed, ' + $script:Failures.Count + ' failed; backend/application execution: 0.')
if ($script:Failures.Count -gt 0) { throw ($script:Failures -join [Environment]::NewLine) }
