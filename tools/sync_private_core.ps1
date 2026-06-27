param(
    [Parameter(Mandatory = $false)]
    [string]$CoreRepository = "..\quell-core"
)

$ErrorActionPreference = "Stop"

function Resolve-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Sync-Addon([string]$Source, [string]$Destination, [string]$AllowedRoot) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Private addon not found: $Source"
    }
    $destinationFull = Resolve-FullPath $Destination
    $allowedFull = Resolve-FullPath $AllowedRoot
    if (-not $destinationFull.StartsWith($allowedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to sync outside addon root: $destinationFull"
    }
    if (Test-Path -LiteralPath $destinationFull) {
        Remove-Item -LiteralPath $destinationFull -Recurse -Force
    }
    New-Item -ItemType Directory -Path (Split-Path $destinationFull) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destinationFull -Recurse -Force
    Write-Output "Installed private addon to $destinationFull"
}

$repoRoot = Resolve-FullPath (Join-Path $PSScriptRoot "..")
$coreRoot = Resolve-FullPath $CoreRepository
$addonRoot = Resolve-FullPath (Join-Path $repoRoot "addons")

Sync-Addon (Join-Path $coreRoot "engines\godot\addons\quell_core") (Join-Path $addonRoot "quell_core") $addonRoot
Sync-Addon (Join-Path $coreRoot "engines\godot\addons\quell_core_native") (Join-Path $addonRoot "quell_core_native") $addonRoot
