param(
    [Parameter(Mandatory = $false)]
    [string]$CoreRepository = "..\quell-core"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$source = Join-Path (Resolve-Path $CoreRepository) "engines\godot\addons\quell_core"
$destination = Join-Path $repoRoot "addons\quell_core"

if (-not (Test-Path $source)) {
    throw "Private core addon not found: $source"
}

if (Test-Path $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}

New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
Copy-Item -Path $source -Destination $destination -Recurse
Write-Output "Installed private core addon to $destination"
