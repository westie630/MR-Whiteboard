# MR Whiteboard

An infinite whiteboard for the **Meta Quest 3** and the **Logitech MX Ink** stylus, built with **Godot 4.7.2**. It runs only in mixed reality (passthrough), is operated with bare hands, and uses the stylus whenever you draw. The same project also runs as a **PC app** so you can try everything without a headset.

<img src="assets/icons/icon_512.png" width="120" alt="MR Whiteboard logo">

## What it does

| | |
|---|---|
| **Draw in 3D** | Draw in the air with the stylus; each 3D sketch is an object you can pick up and move. |
| **Canvases** | Place a canvas on a wall, on a table or in mid-air whenever you want. The grid fades in around the stylus, fades out as you walk away and fades at the edges. Draw past the edge and the canvas grows: it is infinite. |
| **Rooms and anchors** | Every canvas and sketch is fixed in the real room by a Meta **spatial anchor**. The app recognises the room you are in by its anchors, shows only that room's content, and offers to create a room when you walk into a new one. Moving something and letting go fixes it at its new place with a new anchor. |
| **Documents** | Several documents, listed and opened like Word documents, with auto-save. Duplicate, rename, delete. |
| **Brushes** | Pen, marker, highlighter, pencil, calligraphy, neon, spray, dashed. 14 colours plus a full colour picker, width 1-40 mm, pressure sensitive. |
| **Shape recognition** | Hold the stylus still at the end of a stroke and a **straight line, arrow, rectangle, square, circle, ellipse, triangle, diamond, pentagon, hexagon, parallelogram or polygon** snaps to a clean vector shape (or choose "Always"). |
| **Vector shapes** | Snapped shapes are real shapes: select them, drag, resize with handles, rotate, change colour / fill / width. |
| **Flow diagrams** | Stencils (process, decision, start/end, data, document, database ...), arrows and elbow connectors that **stick to the shapes and follow them** when you move them. |
| **Handwriting to text** | Write words with the stylus (Write tool) and pause: they become typed text with the **same size and position** as your handwriting. Written inside a box, the text becomes the box's label. Wrong reading? Tap "next reading". |
| **Export** | **SVG** (one file per canvas, for Inkscape / Illustrator / Figma), **glTF .glb** (3D sketches and canvas ink) and the document file **.mrw**. |
| **PC test app** | Mouse as the stylus, a fly camera as your head, a simulated room and simulated anchors (switch rooms from the Rooms tab). |

## Run it

### On the PC (no headset)

```
godot --path . res://scenes/main.tscn           # or: pwsh tools/pc.ps1
pwsh tools/pc.ps1 -Demo                          # opens a demo document
pwsh tools/pc.ps1 -Export                        # builds build/pc/MRWhiteboard.exe
```

Controls: **left mouse** draws (hover a canvas to draw on it, otherwise it draws in the air), **Ctrl+left** forces air drawing, **Shift+left** is the stylus front button (grab and move), **middle mouse** pinches (carry a canvas, wheel scales it, Q/E turn it), **right mouse** looks around, **WASD** walks, **Ctrl+Z / Ctrl+Y** undo / redo, **C** places a canvas, **1-5** switch tools, **Delete**, **Ctrl+D**, **Ctrl+S**. A graphics tablet gives pressure.

### On the Quest 3

One-time setup:

1. Quest: turn on **Developer Mode**, connect USB and accept the debugging prompt.
2. Quest: run **Space Setup** (Settings > Environment) so the room is scanned: anchors, walls and tables depend on it.
3. Quest: pair the **MX Ink** and choose its hand in **Settings > Devices > Stylus**.
4. PC: install the Godot 4.7.2 export templates, then once `pwsh tools/setup_android.ps1`.

Build and install: `pwsh tools/quest.ps1` (add `-NoInstall` to only build `build/MRWhiteboard-Quest3.apk`, `-Logs` to stream the app log).

Using it: the menu appears in front of you. **Poke** it with the stylus tip or a fingertip, or **point and pinch** from a distance. Grab the bar under it to move it; **open your palm facing up** to bring it back to you.

| Stylus | |
|---|---|
| Tip pressed on a canvas / middle button | draw (pressure sensitive) |
| Hold still at the end of a stroke | snap to a line / shape |
| Front button | grab and move what the tip touches |
| Back button | undo (double tap: redo) |

| Hands | |
|---|---|
| Pinch a canvas or sketch | carry it; letting go fixes it with a new anchor |
| Pinch with both hands | turn and resize |
| Pinch a canvas corner | change its extent |
| Palm up | bring the menu to you |

Without a stylus, a **pinch of the right hand draws** (left hand moves canvases): handy for trying the app.

## Handwriting recognition

Handwriting is read by Google's handwriting input service (the one behind Google Input Tools), which understands real pen strokes with timing: print, cursive, digits, symbols, many languages. It needs an internet connection; only the pen strokes are sent. It is an unofficial endpoint, so if it changes, the app says so and leaves your ink untouched. `InkRecognizer` is a small interface (`src/ink/`) for plugging in another recogniser, for example an on-device model.

## Storage

Documents are JSON (`.mrw`) in the app's data folder (`user://docs`): plain text, with stroke points packed as base64 float arrays so they load fast. Spatial anchors live in the headset's own storage; documents only keep their UUIDs. Duplicating a document shares its anchors; deleting one only erases anchors no other document uses. Exports go to `Documents/MR Whiteboard` on the PC and to the app's `exports` folder on the headset (`adb pull /sdcard/Android/data/com.westie630.mrwhiteboard/files/exports`).

## How it is built

```
src/core/      document model (Document, FrameData, Item), History (undo/redo), DocStore, shape library (Shapes),
               ShapeRecognizer, StrokeMesher, Brushes, SvgExport, Exporter, TextLayout
src/board/     Board (the world: rooms, anchors, frames, selection), PenController, HandController, InkController,
               FrameNode / ItemView (3D views), LiveStroke, AnchorService (+ SimAnchors for the PC)
src/xr/        XrRig, StylusInput, MetaAnchors, MetaScene, XrPanel (compositor-layer menu), hand tracking helpers
src/desktop/   DesktopRig (the PC build)
src/ui/        MenuPanel and the vector-drawn controls (Btn, FlatSlider, HsvPicker, InkField, Icons, UITheme)
src/ink/       InkRecognizer interface and GoogleInk
shaders/       ink (canvas ribbons, 3D tubes, neon), the fading grid
tests/         headless tests: pwsh tests/run_all.ps1
tools/         icons, action map, build scripts, dev renders
```

Ideas worth knowing:

* **Frames.** Everything lives in a *frame*: a canvas (flat, with a grid) or a 3D sketch. A frame has its own spatial anchor and a pose relative to its room's anchor; the room anchor is the fallback and is how rooms are recognised.
* **Anchors follow edits.** Move a frame and it is stale: the board creates a new anchor at the new pose, and erases the old one once the new one is tracked. A frame whose anchor never gets a pose in a room that is here is considered lost and re-anchored.
* **Crisp rendering.** Ink is anti-aliased in the shader (analytic edge from the ribbon's UV), curves are tessellated by length so big circles never show facets, text is an SDF font that stays sharp at any distance, the menu is a vector-drawn Control tree rendered at 2x onto an OpenXR compositor layer (falls back to a textured quad), foveation is off and MSAA is 4x with render scale 1.4 (setting).
* **Undo everywhere.** Every edit goes through `History` as an operation; handwriting conversion, erasing, moving with connectors and so on are single steps.

## Tests

```
pwsh tests/run_all.ps1
```

Covers the shape recogniser (noisy synthetic strokes), the document model, save / load, undo, SVG export, a simulated pen driving the whole board (draw, snap, erase, select, glued connectors, rooms, anchors, hands), the menu pointer mapping at 2x scale and the handwriting service. `tools/dev/render_demo.tscn` and `--screenshot` render real frames for checking by eye.

## Status: what is verified and what needs your headset

Everything above runs and is tested on the PC. The headset-specific parts are written from the OpenXR / Godot / Meta APIs and from the anchor and hand code that already runs on a Quest 3 in the Apex MR project, but **could not be run on a headset while writing this**. First things to check on the device (each has a clear log line, `adb logcat -s godot`):

1. **Stylus**: `[stylus] connected on the right hand` appears, pressure draws. If the nib position is offset or the pointing direction is wrong, the tip pose axis in `StylusInput` is the place to adjust.
2. **Anchors**: `[anchors] created ...` / `saved ...: true`; after restarting the app, `tracking stored anchor ...`. The permissions `USE_ANCHOR_API` and `USE_SCENE` are requested at start.
3. **Menu**: `[panel] compositor layer` (sharpest) or `textured quad`.
4. Handwriting needs internet on the headset.

## Credits

Godot OpenXR Vendors plugin (MIT) by the Godot XR community, bundled in `addons/` (Meta + Windows binaries only). Hand-tracking filtering and the anchor handling grew out of the Apex MR project.
