# Runs every headless test: pwsh tests/run_all.ps1
$godot = "C:\Program Files Portable\Godot Versions\4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe"
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
Get-ChildItem "$root\tests\test_*.gd" | ForEach-Object {
    $name = $_.BaseName
    $out = & $godot --headless --path $root res://tests/runner.tscn -- $name 2>&1
    $out | Where-Object { $_ -match "passed|FAIL|ERROR|SCRIPT" } | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
if ($failed -gt 0) { Write-Host "$failed test file(s) failed"; exit 1 } else { Write-Host "all tests passed" }
