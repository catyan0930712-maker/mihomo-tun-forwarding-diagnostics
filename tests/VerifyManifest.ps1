#Requires -Version 5.1
# Read-only release integrity check. Does not run toolkit/network commands.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$seen = @{}
foreach ($line in @(Get-Content -LiteralPath (Join-Path $root 'MANIFEST.sha256'))) {
    if (-not $line.Trim()) { continue }
    if ($line -cnotmatch '^([a-f0-9]{64})  (.+)$') { throw 'Invalid manifest line.' }
    $expected = $Matches[1]
    $relative = $Matches[2]
    if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $seen.ContainsKey($relative)) {
        throw 'Unsafe or duplicate manifest path.'
    }
    $seen[$relative] = $true
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escaped root.' }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Manifest target is not a regular file.' }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected) { throw ('Hash mismatch: ' + $relative) }
}
if ($seen.Count -eq 0) { throw 'Empty release manifest.' }
$gitRoot = Join-Path $root '.git'
foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -Force -File)) {
    if ($file.FullName.StartsWith($gitRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { continue }
    $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
    if ($relative -eq 'MANIFEST.sha256') { continue }
    if (-not $seen.ContainsKey($relative)) { throw ('File omitted from manifest: ' + $relative) }
}
Write-Host ('Verified SHA-256 manifest: ' + $seen.Count + ' files.')
