# The PC test app (no headset needed).
#   pwsh tools/pc.ps1            # run it from the project
#   pwsh tools/pc.ps1 -Export    # build build/pc/MRWhiteboard.exe
#   pwsh tools/pc.ps1 -Demo      # run with the demo document
param([switch]$Export, [switch]$Demo)

$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "C:\Program Files Portable\Godot Versions\4.7.2-stable\Godot_v4.7.2-stable_win64.exe" }
$console = $godot -replace "_win64\.exe$", "_win64_console.exe"

if ($Export) {
    New-Item -ItemType Directory -Force (Join-Path $root "build\pc") | Out-Null
    & $console --headless --path $root --export-release "Windows PC" (Join-Path $root "build\pc\MRWhiteboard.exe")
    Write-Host "Built build\pc\MRWhiteboard.exe"
    return
}
$extra = if ($Demo) { @("--", "--demo") } else { @() }
& $godot --path $root res://scenes/main.tscn @extra
