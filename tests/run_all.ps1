# Runs every headless test: pwsh tests/run_all.ps1
# A test passes when it prints "<name>: N passed, 0 failed" (Godot's own shutdown noise is ignored).
$godot = if ($env:GODOT) { $env:GODOT } else { "C:\Program Files Portable\Godot Versions\4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe" }
$root = Split-Path -Parent $PSScriptRoot
$bad = 0
Get-ChildItem "$root\tests\test_*.gd" | ForEach-Object {
    $name = $_.BaseName
    $out = & $godot --headless --path $root res://tests/runner.tscn -- $name 2>&1 | ForEach-Object { "$_" }
    $summary = $out | Where-Object { $_ -match "^\S+: \d+ passed, \d+ failed" } | Select-Object -Last 1
    $fails = $out | Where-Object { $_ -match "^\s+FAIL:|SCRIPT ERROR|TIMEOUT" }
    $fails | ForEach-Object { Write-Host $_ }
    if ($summary -and $summary -match ", 0 failed" -and -not $fails) {
        Write-Host $summary
    } else {
        Write-Host "${name}: FAILED  ($summary)"
        $bad++
    }
}
if ($bad -gt 0) { Write-Host "$bad test file(s) failed"; exit 1 } else { Write-Host "all tests passed" }
