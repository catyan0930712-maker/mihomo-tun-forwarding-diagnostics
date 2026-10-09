# Validate syntax only; does not run network commands or modify settings.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = @(Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
if ($scripts.Count -eq 0) { throw 'No PowerShell source files found.' }
foreach ($script in $scripts) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Error "$($script.Name): $($_.Message)" }
        throw 'PowerShell parsing failed.'
    }
    Write-Host "Syntax OK: $($script.FullName)"
}
