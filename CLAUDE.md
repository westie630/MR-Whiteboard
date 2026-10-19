# MR Whiteboard

Godot 4.7.2 Quest 3 + MX Ink mixed-reality whiteboard, with a PC test build. See README.md for what it does and how it is built.

* Compile check: `godot --headless --path . -s tools/dev/check_scripts.gd` (after adding a `class_name` run `godot --headless --path . --import --quit` first).
* Tests: `pwsh tests/run_all.ps1` (each `tests/test_*.gd` is a Node run by `tests/runner.tscn`, because autoloads do not exist for `-s` scripts).
* Look at it: `godot --path . res://scenes/main.tscn -- --demo --screenshot=PATH` (also `--tab=docs`, `--cam=x,y,z,yaw,pitch`, `--docs-dir=`, `--settings=`); `res://tools/dev/sim_draw.tscn` drives the PC app with synthetic mouse events.
* Build: `pwsh tools/quest.ps1` (APK + install), `pwsh tools/pc.ps1 -Export` (exe). Nothing under `src/` may depend on `tools/` or `tests/`: they are left out of exports.
* No headset was available while this was written: the XR code (`src/xr/`) is checked only by `tests/test_xr_rig.gd` on the PC. See "Status" in README.
* Keep the interface vector-drawn (`Btn`, `Icons`, `UITheme`) and the text on the SDF font (`TextLayout.font()`): no bitmap UI.
* GDScript traps seen here: lambdas capture locals by value; `:=` needs a typed right-hand side; `convert` / `duplicate` clash with built-ins.
