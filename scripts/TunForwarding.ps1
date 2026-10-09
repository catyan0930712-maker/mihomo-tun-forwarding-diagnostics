#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only diagnostics and explicitly confirmed IPv4 forwarding recovery.
.DESCRIPTION
  Fix/Restore require an already elevated PowerShell window. No automatic UAC
  relaunch occurs. Importing the core module does not inspect networking.
#>
[CmdletBinding()]
param(
    [ValidateSet('Diagnose', 'Fix', 'Restore')][string]$Mode = 'Diagnose',
    [string]$InterfaceAlias = ''
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows only.' }
    Import-Module (Join-Path $PSScriptRoot 'TunForwarding.Core.psm1') -Force -ErrorAction Stop
    $result = Invoke-TunForwarding -Mode $Mode -InterfaceAlias $InterfaceAlias -Backend (New-WindowsBackend)
    if ($Mode -eq 'Diagnose') {
        Write-Host 'READ-ONLY: no network settings have been changed.'
        $result.Adapters | Format-Table Name, ifIndex, InterfaceDescription, Status -AutoSize | Out-Host
        $result.Ipv4 | Format-Table Name, Forwarding -AutoSize | Out-Host
        $result.Routes | Format-Table InterfaceAlias, NextHop, RouteMetric -AutoSize | Out-Host
        Write-Host ('Sharing/routing inspection known: ' + $result.Safety.Known)
        $result.Safety.Risks | ForEach-Object { Write-Warning $_ }
        Write-Host 'Do not post raw output containing personal adapter names or addresses publicly.'
    } else { Write-Host $result.Message }
    exit 0
} catch {
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
