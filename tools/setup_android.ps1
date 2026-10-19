# One-time setup of the Android Gradle build template (the same as Project > Install Android Build Template in the editor).
# Needs the Godot 4.7.2 export templates installed (Editor > Manage Export Templates).
$root = Split-Path -Parent $PSScriptRoot
$zip = Join-Path $env:APPDATA "Godot\export_templates\4.7.2.stable\android_source.zip"
if (-not (Test-Path $zip)) { throw "Export templates for 4.7.2 not found: $zip" }
$dest = Join-Path $root "android\build"
New-Item -ItemType Directory -Force $dest | Out-Null
Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
Set-Content -Path (Join-Path $root "android\.build_version") -Value "4.7.2.stable" -NoNewline
Set-Content -Path (Join-Path $dest ".gdignore") -Value "" -NoNewline
Write-Host "Android build template installed in $dest"
