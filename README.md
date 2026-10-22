# MR Whiteboard

An infinite whiteboard for the **Meta Quest 3** and the **Logitech MX Ink** stylus, built with **Godot 4.7.2**. It runs only in mixed reality (passthrough), is operated with bare hands, and uses the stylus whenever you draw. The same project also runs as a **PC app** so you can try everything without a headset.

<img src="assets/icons/icon_512.png" width="120" alt="MR Whiteboard logo">

<p>
<img src="docs/pc-demo.png" width="49%" alt="The PC test app with the demo document: a flow diagram, every brush, text and shapes">
<img src="docs/pc-drawing.png" width="49%" alt="Shapes snapped from freehand strokes, a glued arrow, and handwriting converted to text">
</p>

*The PC test app (screenshots): the demo document, and strokes snapped to clean shapes with handwriting read as text.*

## What it does

| | |
|---|---|
| **Canvases** | Place a canvas on a wall, on a table or in mid-air whenever you want. The grid fades in around the stylus, fades out as you walk away and fades at the edges. Draw past the edge and the canvas grows: it is infinite. |
| **Rooms and anchors** | Every canvas and sketch is fixed in the real room by a Meta **spatial anchor**. The app recognises the room you are in by its anchors, shows only that room's content, and offers to create a room when you walk into a new one. Moving something and letting go fixes it at its new place with a new anchor. |
| **Documents** | Several documents, listed and opened like Word documents, with auto-save. Duplicate, rename, delete. |
| **Brushes** | Pen, marker, highlighter, pencil, calligraphy, neon, spray, dashed. 14 colours plus a full colour picker, width 1-40 mm, pressure sensitive. |
| **Shape recognition** | Hold the stylus still at the end of a stroke and a **straight line, arrow, rectangle, square, circle, ellipse, triangle, diamond, pentagon, hexagon, parallelogram or polygon** snaps to a clean vector shape (or choose "Always"). |
| **Vector shapes** | Snapped shapes are real shapes: select them, drag, resize with handles, rotate, change colour / fill / width. Three round buttons beside the selection box undo, redo (200 levels) and delete (a delete is taken back with undo). |
| **Flow diagrams** | Stencils (process, decision, start/end, data, document, database ...), arrows and elbow connectors that **stick to the shapes and follow them** when you move them. |
| **Handwriting to text** | Write words with the stylus (Write tool) and pause: they become typed text with the **same size and position** as your handwriting. Written inside a box, the text becomes the box's label. Wrong reading? Tap "next reading". |
| **Speech to text** | Tap **Dictate**, speak, pause: the words become a text item on the canvas you are looking at (below earlier text, selected so you can move or correct it). The correction box has a Dictate button too. |
| **Typing** | Tap **Type** (or press any key on a Bluetooth keyboard, **T** on the PC): type text onto the canvas you are looking at. With text selected it edits it, with a box selected it becomes the box's label. Works with a **Bluetooth keyboard** and an **on-screen keyboard** at the same time. |
| **Export** | **SVG** (one file per canvas, for Inkscape / Illustrator / Figma), **glTF .glb** (the canvas ink as 3D) and the document file **.mrw**. **Docs > Manage on your PC** also lets a browser on your PC view, download, delete and add canvases (see below). |
| **PC test app** | Mouse as the stylus, a fly camera as your head, a simulated room and simulated anchors (switch rooms from the Rooms tab). |

## Run it

### On the PC (no headset)

```
godot --path . res://scenes/main.tscn           # or: pwsh tools/pc.ps1
pwsh tools/pc.ps1 -Demo                          # opens a demo document
pwsh tools/pc.ps1 -Export                        # builds build/pc/MRWhiteboard.exe
```

Controls (the menu is on the left; **Tab** hides it): **left mouse** draws on the canvas under the pointer, **Shift+left** is the stylus front button (grab: an item, the bar under a canvas, a corner, or empty canvas to carry it), **middle mouse** pinches (carry a canvas, wheel scales it, Q/E turn it), **right mouse** looks around, **WASD** walks, **Ctrl+Z / Ctrl+Y** undo / redo, **C** places a canvas, **1-5** switch tools, **Delete**, **Ctrl+D**, **Ctrl+S**. A graphics tablet gives pressure.

### On the Quest 3

One-time setup:

1. Quest: turn on **Developer Mode**, connect USB and accept the debugging prompt.
2. Quest: run **Space Setup** (Settings > Environment) so the room is scanned: anchors, walls and tables depend on it.
3. Quest: pair the **MX Ink** and choose its hand in **Settings > Devices > Stylus**.
4. PC: install the Godot 4.7.2 export templates, then once `pwsh tools/setup_android.ps1`.

Build and install: `pwsh tools/quest.ps1` (add `-NoInstall` to only build `build/MRWhiteboard-Quest3.apk`, `-Logs` to stream the app log).

Quit with the **Quit** button at the top of the menu (press it twice; the document is saved first).

Using it: the menu appears in front of you. **Touch** a button with the stylus tip or a fingertip, or **point and pinch** (stylus: **front button**) from a distance. Grab the bar under the menu to move it, by touching it or pointing at it; **open your palm facing up** (or hold the stylus front button with nothing to grab) to bring it to you.

One vocabulary for both tools: **point** (a ring shows where), **act** (draw / press), **grab** (pinch, or the stylus front button), **undo**, **menu**. A pointer **touches** a canvas when it is within 12 cm of it, and then grabs 1:1; further away it **points**, and what it grabs moves further than the hand (by the ratio of their distances from your head).

| Stylus | |
|---|---|
| Tip pressed on a canvas / middle button | the current tool: draw (pressure sensitive), write, erase, select, shape |
| Hold still at the end of a stroke | snap to a line / shape |
| Front button | grab, like a pinch: an item is selected and dragged, the bar under a canvas or empty canvas carries it, a corner changes its size. By touch, or by pointing along the stylus |
| Back button | undo, at once. With the front button held: redo |

| Hands | |
|---|---|
| Point | the runtime's hand ray (OpenXR hand interaction profile): a ring shows where it lands |
| Pinch a shape, line or stroke | select it and drag it (its handles reshape it). Hands always arrange, whatever tool the stylus has |
| Pinch empty canvas | let go of the selection (a drag carries the canvas) |
| Pinch the bar under a canvas | carry the canvas; letting go fixes it with a new anchor |
| Pinch a canvas corner | change its extent |
| Second hand on the same canvas | turn and resize |
| Palm up | bring the menu in front of you (also: hold the stylus front button with nothing to grab; a menu more than 2.5 m away comes back by itself) |

Undo and redo are always on the menu's bottom row. A pinch ticks (a soft click) and the stylus pulses: **More > Feedback** switches both off.

Every input, threshold and tunable number is documented in [docs/INTERACTIONS.md](docs/INTERACTIONS.md).

Drawing is the stylus's job and happens only on canvases (drawing in the air is switched off). **More > Draw with a pinch** lets the right hand draw by pinching on a canvas when there is no stylus.

## Handwriting recognition

Handwriting is read by Google's handwriting input service (the one behind Google Input Tools), which understands real pen strokes with timing: print, cursive, digits, symbols, many languages. It needs an internet connection; only the pen strokes are sent. **Bad handwriting:** the service returns several candidate readings; select the converted text and tap another reading, choose **Retype / rewrite** (type on the PC, write a name in the pad in the headset), or **Back to handwriting**, which restores your original strokes (they are kept inside the text, also after saving). Converting happens after a pause you can lengthen, or only when you press **To text**; ink that cannot be read is simply left as ink. Writing a little larger and slower than usual gives the recogniser the most to work with. It is an unofficial endpoint, so if it changes, the app says so and leaves your ink untouched. `InkRecognizer` is a small interface (`src/ink/`) for plugging in another recogniser, for example an on-device model.

## Typing

**Type** opens a box (it replaces the tabs while it is open, so the canvas stays in view): new text goes on the canvas you are looking at, below earlier text and selected so you can move it. With a text item selected the box edits it (one undo step); with a box or other closed shape selected, what you type becomes its **label**. Names of documents, canvases and rooms use the same box on one line. Enter accepts a one-line name; in the text box Enter is a new line and **Ctrl+Enter** or **OK** accepts. **Dictate** works inside the box too, and the keyboard button swaps the on-screen keyboard for the handwriting pad.

* **On-screen keyboard** (`VKeyboard`, vector-drawn): letters, digits, symbols, shift (double tap: caps lock), caret arrows, backspace that repeats. It appears whenever a text field of the menu is edited (also the Wit.ai token box in More) and sends real key events, exactly like a physical keyboard. Keys fire on press, so poke or point-and-pinch like on a real keyboard.
* **Bluetooth keyboard**: pair it in the Quest settings; its keys arrive in the app window and are passed on to the field being edited in the menu. With no field open: any character starts a new text, **Enter** edits the selected text or shape, **Ctrl+Z / Ctrl+Y** undo and redo, **Ctrl+S** save, **Ctrl+D** duplicate, **Delete** removes the selection.

## Speech to text

Dictation records the microphone (the headset's, or the PC's default input), cuts the recording when you stop speaking (or after 19 s), and sends the audio to **Wit.ai**, Meta's free speech service. It needs an internet connection and a Wit.ai token, and only the audio of a dictation is sent.

1. Make a free account at [wit.ai](https://wit.ai), create an app (its language is the language that is recognised) and copy its **Server Access Token** (Settings).
2. **More > Speech to text**, type or paste the token (in the headset with the on-screen or a Bluetooth keyboard). Or bundle it into your own build: `pwsh tools/quest.ps1 -WitToken <token>` bundles the token into your own build (the file `wit_token.txt` is git-ignored and removed again after the export; anyone who has your APK can read it, so keep it personal).
3. Quest: the first start asks for microphone access. Tap **Dictate** (it shows *Listening...*), say something, pause. Tap it again to finish early.

If the PC records silence, Windows is using another input as its default: change it in Windows Sound settings. `SpeechRecognizer` (`src/speech/`) is the small interface for plugging in another service or an on-device model.

## Managing canvases from your PC

**Docs > Manage on your PC > Web page on Wi-Fi** starts a small web server inside the app and shows its address and a 6-digit **access code**. Put the PC on the same Wi-Fi as the headset, open the address (for example `http://192.168.1.23:8080`) in any browser and type the code. The page (light and dark, works on a phone too) offers:

* **Canvases by room**, the room you are in first, with a thumbnail of each, a search box and tabs per room.
* **View** one canvas large (white, dark or transparent background, zoom, next / previous with the arrow keys), **Download SVG**, or download a whole room or everything as a **zip** (one folder per room). Tick several canvases to **download or delete just those**.
* **Rename** and **Delete** canvases. A delete is a normal undoable step in the headset (the Undo button brings the canvas back).
* **Upload SVG**: drop one or more `.svg` files on the page. Each becomes a **new canvas standing in front of you in the headset**, made of real items you can edit like anything you drew: rectangles, ellipses and lines become shapes (select, move, resize, recolour, glue connectors), polygons and closed paths become filled polygons, open paths and curves become pen strokes, text stays text (edit it with the Type button). Colours, fills, stroke widths, opacity, transforms, style sheets and `<use>` are honoured; a page-sized background rectangle is left out and the canvas backing (white for dark ink, dark for light ink) is chosen to suit. Small drawings (an A4 page, an icon) are enlarged to 90 cm so they can be edited in a room; very large ones are reduced to 2.4 m. Not carried over, and listed after the upload: embedded images, patterns, clip paths and masks, filters, arrow markers; gradients become one colour, holes in a filled path are filled, dashes become solid. Up to 4000 shapes per file, 16 MB. The whole import is one undo step.
* **Saved on the headset**: the files the Export buttons made (`.svg`, `.glb`, `.mrw`), to download or delete.

It serves the document as it is at that moment, and the page tells you when the headset has changed something (Refresh). It is off whenever the app starts and only listens while the switch is on. The code is new each time it is switched on; five wrong codes in a row lock that address for a minute; changes are only accepted from the page itself (a same-site cookie and a header other sites cannot add); the pages and SVG files carry a content security policy. The connection is plain HTTP, so use it on a network you trust: anyone on it who learns the code can change your canvases. The app has to be running and the headset awake (the server pauses when you take the headset off). On the PC test app the same switch is in the Docs tab, and `godot --path . res://scenes/main.tscn -- --share` starts it at launch (`--share=nopin` leaves out the code, for scripts); it then also answers on `http://127.0.0.1:8080`.

## Storage

Documents are JSON (`.mrw`) in the app's data folder (`user://docs`): plain text, with stroke points packed as base64 float arrays so they load fast. Spatial anchors live in the headset's own storage; documents only keep their UUIDs. Duplicating a document shares its anchors; deleting one only erases anchors no other document uses. Exports go to `Documents/MR Whiteboard` on the PC and to the app's own `exports` folder on the headset; the full path is shown in the app after an export (the Docs tab) and can be fetched with `adb pull`. The easier way to get canvases off the headset is the Wi-Fi viewer above.

## How it is built

```
src/core/      document model (Document, FrameData, Item), History (undo/redo), DocStore, shape library (Shapes),
               ShapeRecognizer, StrokeMesher, Brushes, SvgExport, Exporter, SvgImport, ExportServer + WebPages + WebAssets (the Wi-Fi web page), TextLayout,
               InputTuning (every number that decides how hands, stylus and menu feel)
src/board/     Board (the world: rooms, anchors, frames, selection), PenController, HandController, InkController, TextController, Shortcuts,
               FrameNode / ItemView (3D views), LiveStroke, AnchorService (+ SimAnchors for the PC)
src/xr/        XrRig, StylusInput, HandInput, HandCursor, Feedback (click sounds), MetaAnchors, MetaScene, XrPanel (compositor-layer menu)
src/desktop/   DesktopRig (the PC build)
src/ui/        MenuPanel and the vector-drawn controls (Btn, FlatSlider, HsvPicker, InkField, VKeyboard, TextEntry, Icons, UITheme)
src/ink/       InkRecognizer interface and GoogleInk
src/speech/    MicRecorder (microphone, speech detection, 16 kHz conversion), SpeechRecognizer interface and WitSpeech
shaders/       ink (canvas ribbons, 3D tubes, neon), the fading grid
tests/         headless tests: pwsh tests/run_all.ps1
tools/         icons, action map, build scripts, dev renders
```

Ideas worth knowing:

* **Frames.** Everything lives in a *frame*: a canvas (flat, with a grid). Documents can also hold 3D sketches from older versions; they are kept in the file but not shown, since drawing in 3D is switched off. A frame has its own spatial anchor and a pose relative to its room's anchor; the room anchor is the fallback and is how rooms are recognised.
* **Anchors follow edits.** Move a frame and it is stale: the board creates a new anchor at the new pose, and erases the old one once the new one is tracked. A frame whose anchor never gets a pose in a room that is here is considered lost and re-anchored.
* **Crisp rendering.** Ink is anti-aliased in the shader (analytic edge from the ribbon's UV), curves are tessellated by length so big circles never show facets, text is an SDF font that stays sharp at any distance, the menu is a vector-drawn Control tree rendered at 2x onto an OpenXR compositor layer (falls back to a textured quad), foveation is off and MSAA is 4x with render scale 1.4 (setting).
* **Undo everywhere.** Every edit goes through `History` as an operation; handwriting conversion, erasing, moving with connectors and so on are single steps.

## Tests

```
pwsh tests/run_all.ps1
```

Covers the shape recogniser (noisy synthetic strokes), the document model, save / load, undo, SVG export, the Wi-Fi web page (access code, pages, zips, delete / rename / upload through a real board with undo, saved files, answers over a real local connection), SVG import (shapes, curves, arcs, text, style sheets, transforms, limits), a simulated pen driving the whole board (draw, snap, erase, select, glued connectors, rooms, anchors, hands), the menu pointer mapping at 2x scale, the handwriting service, speech to text (recorder, Wit.ai answer parser, text placement), and typing (on-screen and physical keys, new / edited / labelled text, names). `tools/dev/render_demo.tscn` and `--screenshot` render real frames for checking by eye.

## Status: what is verified and what needs your headset

Everything above runs and is tested on the PC. The headset-specific parts are written from the OpenXR / Godot / Meta APIs and from the anchor and hand code that already runs on a Quest 3 in the Apex MR project, but **could not be run on a headset while writing this**. First things to check on the device (each has a clear log line, `adb logcat -s godot`):

1. **Stylus**: `[stylus] connected on the right hand` appears, pressure draws. If the nib position is offset or the pointing direction is wrong, the tip pose axis in `StylusInput` is the place to adjust.
2. **Anchors**: `[anchors] created ...` / `saved ...: true`; after restarting the app, `tracking stored anchor ...`. The permissions `USE_ANCHOR_API` and `USE_SCENE` are requested at start.
3. **Menu**: `[panel] compositor layer` (sharpest) or `textured quad`.
4. Handwriting needs internet on the headset.
5. **Dictation**: the microphone permission prompt appears, `Listening...` shows while you speak, and the text arrives. The recording code is verified on the PC with a real microphone and with synthetic audio; the Quest side (the RECORD_AUDIO permission, the headset's audio input) has not been run on a headset, nor has a real Wit.ai request been made (no token here: the request format follows Wit.ai's `/dictation` documentation, and the answer parser is tested against its streamed JSON).

6. **Typing**: the on-screen keyboard pokes work (keys fire on press) and a paired Bluetooth keyboard types into the box. The key routing is tested on the PC with synthetic key and pointer events only; whether Horizon OS hands a paired keyboard's keys to an immersive app, and the text field's own system keyboard staying off (`virtual_keyboard_enabled = false`), have not been seen on a headset.

7. **Web page**: switch it on in Docs and open the address on a PC. The server, the pages (driven in a real Chrome: sign in, upload, rename, delete, bulk delete, viewer) and the SVG import are tested on the PC, but not on a headset: whether Horizon OS lets the app listen, which address it reports, and how an imported canvas looks and feels in the room are unchecked. If the page does not load, check that both devices are on the same Wi-Fi without client isolation (guest networks often block it) and that the PC's firewall is not the problem.

## Credits

Godot OpenXR Vendors plugin (MIT) by the Godot XR community, bundled in `addons/` (Meta + Windows binaries only). It is used only where Godot has no core equivalent on the Quest: passthrough, Meta spatial anchors and the room scan. Hands and the MX Ink stylus go through Godot's own action map (`openxr_action_map.tres`: the core hand interaction profile and the core Logitech MX Ink profile). Hand-tracking filtering and the anchor handling grew out of the Apex MR project.
