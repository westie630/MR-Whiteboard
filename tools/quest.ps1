# Export the Quest 3 build with Godot 4.7.2, install it over adb and launch it.
#   pwsh tools/quest.ps1                # export + install + launch
#   pwsh tools/quest.ps1 -NoInstall     # only export build/MRWhiteboard-Quest3.apk
#   pwsh tools/quest.ps1 -NoExport      # install the last build and launch
#   pwsh tools/quest.ps1 -Logs          # also stream the app's log lines after launching (Ctrl+C to stop)
param([switch]$NoExport, [switch]$NoInstall, [switch]$Release, [switch]$Logs)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$godot = if ($env:GODOT) { $env:GODOT } else { "C:\Program Files Portable\Godot Versions\4.7.2-stable\Godot_v4.7.2-stable_win64_console.exe" }
$adb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
$apk = Join-Path $root "build\MRWhiteboard-Quest3.apk"
$log = Join-Path $root "build\export.log"
$pkg = "com.westie630.mrwhiteboard"

if (-not $NoExport) {
    if (-not (Test-Path (Join-Path $root "android\build\build.gradle"))) {
        throw "The Android build template is missing. Run tools/setup_android.ps1 once."
    }
    New-Item -ItemType Directory -Force (Join-Path $root "build") | Out-Null
    Remove-Item $log -ErrorAction SilentlyContinue
    $mode = if ($Release) { "--export-release" } else { "--export-debug" }
    # Godot's headless Android export sometimes lingers after it has written the APK (the Gradle daemon keeps it alive),
    # so watch the log for completion instead of waiting for the process to exit.
    $p = Start-Process -FilePath $godot -ArgumentList @("--headless", "--path", "`"$root`"", $mode, "`"Meta Quest 3`"", "`"$apk`"") `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddMinutes(20)
    $done = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $log) {
            $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
            $clean = $text -replace ([string][char]27 + "\[[0-9;]*m"), ""
            if ($clean -match "DONE\s*\]\s*export") { $done = $true; break }
        }
        if ($p.HasExited) { $done = ($p.ExitCode -eq 0); break }
    }
    Start-Sleep -Seconds 2
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    if (-not $done -or -not (Test-Path $apk)) { throw "export failed; see $log" }
    Write-Host "Exported $apk"
}

if ($NoInstall) { return }
$dev = & $adb devices | Select-String "device$"
if (-not $dev) { throw "No headset found. Enable developer mode, connect USB and accept the debugging prompt." }
& $adb install -r $apk
& $adb shell am start -n "$pkg/com.godot.game.GodotAppLauncher"
Write-Host "Launched $pkg."
if ($Logs) {
    & $adb logcat -c
    & $adb logcat -s godot
} else {
    Write-Host "Logs: adb logcat -s godot   (lines starting [xr] [stylus] [anchors] [panel] [board])"
}
