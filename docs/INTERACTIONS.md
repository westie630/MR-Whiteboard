# Interactions: how the hands and the stylus work the menu and the whiteboard

This is the specification of what the code does, read from the source. Nothing here has been checked on a headset: see "Status" in the
README. Every number is a named constant in [input_tuning.gd](../src/core/input_tuning.gd): section 12 lists them all.

Contents: [1 Vocabulary](#1-vocabulary) · [2 One vocabulary for both tools](#2-one-vocabulary-for-both-tools) · [3 Inputs](#3-the-inputs) ·
[4 Pinch](#4-how-a-pinch-is-recognised) · [5 Grabbing: touch or point](#5-grabbing-touch-or-point) · [6 Menu](#6-the-menu) ·
[7 Bringing the menu](#7-bringing-the-menu-to-you) · [8 Stylus on the board](#8-stylus-on-the-board) · [9 Hands on the board](#9-hands-on-the-board) ·
[10 Placing a canvas](#10-placing-a-canvas) · [11 Feedback](#11-feedback-what-you-see-hear-and-feel) · [12 Tuning](#12-every-tunable-number) ·
[13 PC](#13-pc-test-build-equivalents) · [14 Decisions](#14-decisions-and-what-stays-different)

---

## 1. Vocabulary

| Word | Meaning |
|---|---|
| **Pointer** | Anything that can act on the board: a hand, or the stylus. |
| **Nib** / **tip** | The 3D position of the stylus tip (`PenState.tip`). |
| **Stylus ray** | A line from the nib along the body of the stylus (`PenState.dir`): −Z of the runtime's aim pose for the stylus, which on the MX Ink is −Z of the nib pose too, so twisting the stylus does not swing it. Not the line from the grip pose to the nib: the grip pose sits 3 cm off the stylus's centre line, so that line is 18° off (measured on a Quest 3). |
| **Hand ray** | The runtime's *aim pose* for a hand (the same ray Quest's own menus use). Falls back to knuckle-to-fingertip when the runtime does not report the hand interaction profile. |
| **Pinch** | Thumb and index finger closed (`HandInput`). The hand's "click" and "grab". |
| **Pinch point** | The point between thumb tip and index tip. For the stylus it is the nib. It is what *carries* things. |
| **Grab** | A pinch, or the stylus **front button**. One word for both: they are the same gesture. |
| **Touch** / **point** | A pointer *touches* a canvas or the menu when its pinch point (nib) is close to it, and *points* at it with a ray otherwise. |
| **Canvas** | A flat drawing surface in the room (`FrameData.CANVAS`). The stylus draws on its plane. |
| **Bar** | The grab handle 7 cm under a canvas. The menu has its own, under the panel. |
| **Captured** | A source (`pen`, `left`, `right`) that is touching or pressing the menu this frame. The board ignores captured sources. |

---

## 2. One vocabulary for both tools

Five verbs. Each is the same gesture for every tool, so what you learn on one carries to the other.

| Verb | Hands | Stylus | What it does |
|---|---|---|---|
| **Point** | hand ray; a ring shows where | stylus ray (nib away from the canvas); the same ring, and a beam out of the nib | shows what a grab would pick up |
| **Act** | (hands never draw; with "Draw with a pinch" the right hand's pinch is the nib) | tip or middle button | the current tool: draw, write, erase, select, shape |
| **Grab** | pinch | front button | select and drag an item · carry a canvas (bar, empty canvas) · resize (corner) · move the menu (its bar) |
| **Undo** | menu buttons | back button; menu buttons | undo (redo: front and back together, or the menu button) |
| **Menu** | open palm facing up, 0.6 s | front button held 0.6 s with nothing to grab | brings the menu in front of you, at the same spot |

And one rule for *where* a grab lands, shared by the menu and the canvases: **touching is direct, pointing is geared.** Within 12 cm of a
canvas (7 cm of the menu's bar) the pinch point itself picks and carries, 1:1. Further away the ray chooses what is grabbed, and the
thing moves further than the hand by the ratio of its distance from the head to the hand's (1× to 6×).

---

## 3. The inputs

### 3.1 Stylus (Logitech MX Ink), [stylus_input.gd](../src/xr/stylus_input.gd)

| Physical | Reading | Threshold |
|---|---|---|
| Tip pressure | `tip_force` | down at > 0.035, up at < 0.018 |
| Middle button (pressure sensitive) | `middle_force` | down at > 0.09, up at < 0.05 |
| **Pen down** | tip **or** middle | the two are OR-ed: the middle button *is* the nib to the app |
| **Contact** (`pen.contact`) | tip only, same thresholds | the nib itself is pressed against something. Only this feels the desk (section 10.1): the middle button pressed in the air is not a surface |
| Pressure value | `max(tip, mid) ^ 0.75` | applied only while down |
| Front button | `front_click` | digital: **grab** |
| Back button | `back_click` | digital: **undo** |
| Dock | `dock` | while docked the stylus is treated as **not tracked** (hands take over) |
| Haptic | `trigger_haptic_pulse` | see 11.2 |

- Which hand holds it: setting `stylus_hand` (auto: right first, then left, whichever reports a pose).
- **The hand holding the stylus does not point or pinch**: it is skipped for the menu ray, the board and the palm-up gesture. This is a physical limit, not a rule to remove.
- Hand tracking while the stylus is held depends on `XR_META_simultaneous_hands_and_controllers`; the rig re-requests it whenever the stylus appears.

### 3.2 Hands, [hand_input.gd](../src/xr/hand_input.gd)

Each hand is reduced to:

| Output | Source |
|---|---|
| `aim_o`, `aim_d` | the (stabilised) hand ray: see section 4 |
| `pinching`, `pinch_down`, `pinch_up` | pinch state machine: see section 4 |
| `pinch_point` | midpoint of the raw thumb tip and index tip |
| `tip` | the runtime's `hand_poke` pose, else the filtered index tip joint |
| `palm`, `palm_up` | palm joint; `palm_up` when the palm normal's Y > 0.6 |
| `aiming` | the ray is usable: pointing forward (`aim · head_forward > 0`; `> 0.1` for the joint fallback) **and not palm-up** |

A hand that disappears for less than `LOST_GRACE` (0.15 s) is bridged; after that it counts as lost and lets go of everything it held.
Pinch strength comes from the runtime (`hand_pinch`) when the interaction profile is active, else from the thumb-index distance
(1.0 at 22 mm, 0.0 at 65 mm).

### 3.3 The stylus as a pointer, [hand_controller.gd](../src/board/hand_controller.gd)

For grabbing, the stylus is fed to the same code as a hand (`HandController._feed_stylus`): nib = pinch point, stylus ray = hand ray,
front button = pinch. A front press only counts as a grab if it **begins with the nib free**: not while the tip is down, and not
while a tool is in the middle of a gesture (a shape being dragged uses the front button to keep it square). While the front button
holds something, the tip draws nothing (`PenController.blocked`).

---

## 4. How a pinch is recognised

The hand moves while the fingers close, and the raw ray slides off whatever it was on. So the ray is **frozen while the fingers
close** and the click lands where you were pointing *before* you started closing.

```
strength   0 ──── 0.2 ───── 0.35 ───────── 0.6 ───────── 0.9 ──── 1
phase      OPEN      │ CLOSING (ray held) │ PINCHED / RELEASING │
                CLOSE_CANCEL  CLOSE_START   PINCH_OFF        PINCH_ON
```

| Phase | Ray you see (`aim_*`) | Event |
|---|---|---|
| OPEN | live | |
| CLOSING (strength ≥ 0.35) | held at the position where the strength *began* to rise (walks back through 0.6 s of history, ignoring rises < 0.003/frame as noise) | back to OPEN if strength falls below 0.2 |
| PINCHED (≥ 0.9) | live ray **relative to** the held point, so a drag starts exactly where the pinch landed | `pinch_down` for one frame; `press_o/d` = the held ray |
| RELEASING (< 0.6) | still relative | `pinch_up` for one frame |
| back to OPEN | live again when strength < 0.2 | |

- **Re-pinch**: closing again from RELEASING (≥ 0.9) before reaching < 0.2 is a new click at the same relative ray.
- Hysteresis is 0.9 on / 0.6 off. Everything that "clicks" a hand uses `pinch_down` (press) and `pinch_up` (release).
- Signal filtering (One-Euro): index tip (min cutoff 2.5, beta 45), knuckle (1.0, 30), palm (1.5, 6).

---

## 5. Grabbing: touch or point

Code: `HandController.target_of()`. The same for each hand and for the stylus's front button.

### 5.1 What a pointer is on

1. **Touching.** The pinch point (nib) is within **12 cm** of a canvas plane (in front or behind) and inside the canvas extent grown by **20 cm**, and the palm is not up. It stays "touching" until it is 1.3× further away, so the edge does not flicker. The target is the pinch point projected onto the canvas.
2. **Pointing.** Otherwise, the pointer must be `aiming` and its ray (the *held* ray at the moment of a press) must meet a canvas within 20 cm outside its extent. Locked canvases are skipped; the nearest wins.

### 5.2 What it is on (priority, top wins)

`HandController.classify()`, the same test in both modes:

| # | Kind | Test | Ring colour |
|---|---|---|---|
| 1 | **item** (selection handle) | on a handle of the current selection | cyan |
| 2 | **item** (action button) | on undo / redo / delete beside the selection | cyan |
| 3 | **item** (stroke / shape / text) | within 13 mm × reach of one | cyan |
| 4 | **item** (inside a box) | inside a closed shape | cyan |
| 5 | **bar** | within 20 cm × 7 cm (half-extents) of the bar centre, 7 cm under the canvas | amber |
| 6 | **corner** | within 7.5 cm of a canvas corner | amber |
| 7 | **canvas** | anywhere else on the canvas | white |

Reach: pick radii are multiplied by **1.6** when touching (a finger is not a nib) and **2.6** when pointing (a ray at arm's length is
not a finger). Radii are in world metres, so on a scaled canvas they stay the same on screen.

### 5.3 What a grab does

| Grab on... | Action | Release |
|---|---|---|
| **Item** | select it and drag it; handles reshape it (corners scale, edge stretches, top handle rotates with a 15° snap). Identical to the **Select** tool *whatever tool is chosen*, with one difference: **no lasso** (except pointing with the Select tool, see Empty canvas). A grab inside an unselected box selects the box and drags it | commit (one undo step) |
| **Empty canvas** | undecided: the pointer must move **2 cm** to become a **canvas carry**; if you let go first it is a **tap** that clears the selection. **Pointing with the Select tool chosen**: a **lasso** instead, drawn where the ray runs (`PenController.lasso_ok`); the canvas is then carried by its bar or with two hands | tap = deselect; a loop selects what is >= 60 % inside it |
| **Bar** | **carry the canvas.** The canvas follows the pinch point | the canvas stays; new anchor |
| **Corner** | **resize**: the corner follows the pointer on the canvas plane, the opposite corner stays fixed. Minimum size 0.25 × 0.18 m | commit |
| **Anywhere on a canvas already carried by the other hand** | joins that canvas (second hand, or the stylus's front button): see 9.2 | |
| Nothing | nothing (logged) | |

- The grab is decided at the **held ray** (`press_o/d`, section 4) when pointing, and at the pinch point when touching.
- **Carry gain**: touching it is 1:1. Pointing, gain = distance(head, canvas) / distance(head, pinch point), clamped **1 to 6**, minimum denominator 0.25 m.
- A carry / resize ends when the pinch opens (front button released), the pointer is lost, the ray stops aiming (pointing corner only), or the canvas disappears.
- First-ever carry shows a one-off toast explaining it.

---

## 6. The menu (the interface's panels)

Code: `_update_menu()` in [xr_rig.gd](../src/xr/xr_rig.gd), pointer to mouse conversion in [xr_panel.gd](../src/xr/xr_panel.gd), what shows
when in [ui_shell.gd](../src/ui/ui_shell.gd).

"The menu" is a set of small panels ([UiShell](../src/ui/ui_shell.gd)), each on its own `XrPanel` and shown only when it is needed:

| Panel | Where it floats | Shown |
|---|---|---|
| **Dock** (tools, brush, undo / redo, Add, assistant, Home) | low in front of you (section 7) until you move it by its handle; then where you left it in the room, kept by an anchor across restarts, the headset off and on and recentring (it comes in front at start only if that place is over 2.5 m away or not found in 5 s) | always |
| **Popover** (Brush, Shapes, Handwriting, Add) | standing on the dock, over the button it came from | tap the active tool again, the brush chip, or Add; drawing on a canvas closes it |
| **Typing card** (text box + keyboard) | standing on the dock | Type, renaming, keys |
| **Home**, **Assistant** | beside the dock (left / right), a little higher, turned to you; each has a handle, and once moved opens where it was left (if within 2.5 m) | from the dock; Esc / close; open again after a restart if they were open |
| **Selection bar**, **ink chip**, **suggestion bar** | pinned to the canvas, 12 mm in front of it: above the selection, right of handwriting, inside the top of a canvas with an AI suggestion | while there is one; they step away while the pen draws or a hand carries something |
| **Message** | 0.75 m ahead, a little above the eyes, following the head lazily | a few seconds |

Every panel fades back while the pen draws, erases, selects or drags, or a hand carries something (setting `ui_fade`), and returns 0.35 s
after. Only a panel's own surface catches pointers: its texture is larger (room for tooltips, for growing), and the empty part lets rays and
pokes through to what is behind. When several panels are reached, a touch beats a ray and the nearest wins.

### 6.1 Two ways to press a menu button, the same for both tools

| | **Touch** | **Point and press** |
|---|---|---|
| Stylus | Nib within the touch zone: **presses at < 15 mm** from the panel plane, releases at > 30 mm | Along the stylus body: **front button**. The nib does *not* click from a distance |
| Hand | Fingertip (poke pose) within the same zone, same 15 / 30 mm | Hand ray: **pinch** (`pinch_down` presses, `pinch_up` releases). Needs `aiming` |

Rules for both:

1. **Touch zone**: inside the panel's rectangle (+1 cm margin) and between **5 cm behind** and **8 cm in front** of the panel. Touch takes precedence over the ray for the same source.
2. **Ray reach**: the ray must hit the panel within **1.4 m**, with no canvas nearer than the panel along the ray (by more than 5 cm): then the pinch belongs to the canvas.
3. **A press must begin on the menu.** A pinch that closed on a canvas, then drags across the menu, does not turn into a menu press. A press that began on the menu stays the menu's until it opens.
4. **At a canvas the stylus draws and grabs.** With the nib within 12 cm of a canvas the stylus is not offered the menu, by touch or by ray, so a menu behind a canvas never steals a stroke. Move the menu away, or lift the stylus. *Exception:* the bars pinned to the canvas (selection bar, ink chip, suggestion bar) are touched with the nib like the canvas itself, as long as the pen is not in the middle of a stroke.
5. **One pointer at a time.** The one holding a press keeps it; then one that is pressing or touching; then the one that already had the pointer; then the first in the order *stylus, left hand, right hand*.
6. **Capture** is by touching or pressing only. A ray that merely passes through the menu shows its ring there but the hand is still the board's.
7. **Release outside**: if the pointer leaves the panel while pressed, it releases at (-1,-1), so no button fires.

### 6.2 What a "click" is

The panel turns pointer events into mouse events. A `Btn` fires on **release inside the button** that was **pressed** (`Btn._gui_input`). So:
press and slide off = cancel; pinch down on one button and release on another = nothing.

### 6.3 Scrolling lists

A press inside a `ScrollContainer` is **held back** until it is known whether it is a tap or a drag (`xr_panel.gd`):

| Movement since the press | Result |
|---|---|
| > 14 px **vertical** (and more vertical than horizontal) | scroll the list, following the pointer 1:1; no click |
| > 22 px (14 × 1.6) **horizontal** | released into the control as a normal press-drag |
| Release without either | a tap: press + release at the *press* position |

Controls that must not wait (sliders, colour picker, ink pad, on-screen keyboard) are marked `drag_ctrl` and receive the press immediately.

### 6.4 Moving the menu

The handle is a capsule under the panel (`HANDLE_Y` = 3 cm below it). It is a bar like a canvas's: **grab** it (pinch / front button) the way you grab a canvas:

| | Hover | Start | Move | Drop |
|---|---|---|---|---|
| **Touching**: pinch point (nib) within **7 cm** of the handle | brighter | `pinch_down` / front button pressed | follows the point 1:1 (keeping the offset at the grab) | open the pinch / release the front button |
| **Pointing**: ray passes within **6 cm** of the handle (within 1.4 m) | brighter | same | follows the point with gain 1 to 6 (distance ratio from the head) | same |

While held the panel turns to face the head. Handle colour: dim teal idle, bright teal hover, white held. A press that begins on the handle
captures the pointer; merely hovering does not. A ray that is on a panel never grabs a handle by pointing (the dock is only ~5 cm tall, so
its handle is close to its buttons). The dock, Home and the Assistant have handles; what stands on the dock (a popover, the typing card)
moves with it, the bars on a canvas move with the canvas.

---

## 7. Bringing the menu to you

| Gesture | Condition | Result |
|---|---|---|
| **Palm up** (either hand except the stylus hand) | palm normal Y > 0.6, hand **not pinching**, palm within **0.7 m** of the head, held **0.6 s** | the menu appears in front (below) |
| **Stylus front button held** | **0.6 s**, nib **not** within 14 cm of a canvas (slack 0.2 m), the stylus ray **not on a canvas**, no canvas being carried, not using the menu | the menu appears in front (below); haptic tick; once per press |
| Any printable key on a Bluetooth keyboard / Enter | | shows it and opens the text box |
| Esc on a Bluetooth keyboard | | closes the topmost: typing card, popover, side panels, then lets go of the selection |
| Put the headset on again (`session_focussed`) | | placed in front |
| Menu > **2.5 m** from the head (and not being moved) | | brought back in front |
| First frame the head is above 0.3 m | | placed in front |

"In front" is the same place for all of them: the middle of the dock's lower edge **0.55 m ahead and 30 cm down** of the head, turned
(and tilted) to face it, low like a keyboard so it stays out of the view; open side panels come along beside it. Palm up also
blocks a hand from pointing (`aiming` is false when palm-up), so the summon gesture cannot click anything. Re-arm: after a palm summon
the gesture needs the palm to be away for 2 s.

---

## 8. Stylus on the board

Code: [pen_controller.gd](../src/board/pen_controller.gd). Works the same for the stylus, the PC mouse, and a pinch when "Draw with a pinch" is on.

### 8.1 Where the tools work: the capture zone

The tools are **direct**: what matters is the nib's 3D position, not a ray. A canvas takes the nib when the nib is within **12 cm** of the canvas plane (in front *or behind*) and inside the canvas extent grown by **60 cm** (so drawing past the edge extends the canvas).

- Because activation is by **pen pressure** (tip or middle button) and not by touching a surface, you can draw while hovering within 12 cm of a virtual canvas. The stroke is flattened onto the plane (`z = 0`).
- No canvas in range: the Draw / Write / Shape tools toast ("Draw on a canvas...") and do nothing. Drawing in the air is switched off.
- The closest canvas wins. Locked canvases are ignored.

### 8.2 The buttons

| Control | Action | Details |
|---|---|---|
| **Tip or middle button** pressed | the **current tool** acts (8.3) | before the tool: (1) a press on an undo / redo / delete button beside the selection presses it; (2) a press on a handle of the current selection grabs the handle. Both work with **every** tool |
| **Front button** pressed | **grab** | exactly a hand's pinch (section 5), touching or pointing. Not while the tip is down |
| **Back button** | **undo**, at once | with the front button held (and nothing in progress): **redo**. Also cancels canvas placement |
| Front button during **Shape** drag | constrain to square / circle | |
| Front button during a **shape handle drag** | keep aspect ratio | |
| Front button held, nothing to grab | summon the menu | section 7 |

### 8.3 The tools (menu, "tool" setting)

| Tool | On pen-down | While down | On release |
|---|---|---|---|
| **Draw** | starts a stroke at the nib (brush, colour, width from settings; pressure-sensitive) | adds a sample every 0.9 mm; nib smoothed with a One-Euro filter | stroke saved (decimated to 1.5 mm, lightly smoothed). With **Recognize = Always** the stroke becomes a shape if it looks like one |
| **Draw** + Recognize = *Hold still* | | holding still (within **4 mm**) for **`hold_seconds` (0.55 s, 0.25 to 1.2)** after at least 6 samples snaps to a clean shape (toast + haptic). A progress ring fills from 0.12 s. Moving > **24 mm** from the snap point un-snaps it | the snapped shape is kept |
| **Write** | as Draw but always the plain pen and never snaps | | the stroke goes to handwriting recognition; converts to text after `ink_pause` (2 s) or when "To text" is pressed |
| **Erase** | sweeps | anything within **14 mm** of the nib is hidden; works on canvases and 3D sketches | all swept items are removed as one undo step |
| **Select** | handle > item (13 mm pick) > inside a selected box (drag it) > otherwise a **lasso** starts. **Handle vs body:** the handles stand on the shape's own corners and edges, so over the *body* (inside the shape, along a line, inside a group's box) a handle is only grabbed at its very centre (`HANDLE_INSIDE` 12 mm x sqrt(reach), at most `HANDLE_BODY_FRAC` 22 % of the smaller side, at least 4 mm); just outside the body its zone is the full `HANDLE_HIT` x reach. Inside moves, just outside a corner reshapes ([PenController.hit_handle](../src/board/pen_controller.gd)); hands and the stylus share it | dragging an item moves it; dragging a handle reshapes it | lasso selects items that are **≥ 60 %** inside; a tap (tiny loop) selects the box under the nib; a loop that is empty toasts "Nothing inside the loop" |
| **Shape** | places a stencil: drag from the anchor point | dragging sets size; < 25 mm = default size; lines snap their angle and **glue to shapes** at their ends | adds the shape (a line shorter than 2 cm is dropped) |

Moving a shape moves glued connectors with it; moving a connector alone unglues it from shapes that did not move.

### 8.4 Stylus summary in one line

> Tip / middle = **do** (tool). Front = **grab** (like a pinch). Back = **undo** (with front: redo). Hold front with nothing to grab = **menu**.

---

## 9. Hands on the board

Code: [hand_controller.gd](../src/board/hand_controller.gd). Unless "Draw with a pinch" is on and there is no stylus, **hands never draw**.
**Hands arrange; the stylus marks.** A pinch does the same thing whichever tool is chosen: it is the Select tool's moves, without the lasso,
plus carrying and resizing canvases. The one exception: with the **Select** tool chosen, a pinch (or the stylus front button) *pointing* at
empty canvas draws a lasso, so things can be gathered from a distance; touching, it still carries the canvas. Nothing is picked up by accident: what a pinch does depends *only* on what the pointer is on (section 5).
A hand in Erase mode selects, it never erases.

### 9.1 Touching or pointing

Both work for hands. Reach out and pinch on the canvas, or stand back and point. What a hand is on is shown by the ring and the corner dots
and bar of the canvas (section 11.1).

### 9.2 Two hands on one canvas

**Place locked** (`FrameData.place_locked`, Home > Canvases, the arrows-and-padlock button): the canvas keeps where it is and which way it faces. A pinch on its bar or
empty canvas holds it but it does not follow (the first try says why), so two hands *only* resize it, about the middle of its extent, never turning or
moving it (a curved desk: they only zoom its contents; one pointer still slides them). Bring to me, laying it on or standing it up from a desk, curving it,
lining a curved desk up, the PC's Q / E and desk tracking leave it alone; a corner still changes its extent, flattening a curved desk keeps it where it is.
A hold that changed nothing leaves no undo step and keeps the anchor. `locked` locks everything; this locks only the place.

**Hidden** (`FrameData.hidden`, Home > Canvases, the eye button): the canvas is not shown and, because every pen, hand and ray target comes from
`Board.visible_frames`, nothing reaches it; its items stay in the document (and in exports), and a selection on it is dropped. It is saved and goes to a
session's guests like `locked`; a guest can hide one only where the session lets guests edit canvases. Undo shows it again.

**Carried by one pointer, a canvas turns to face you**, as a panel does while its handle is held: about the vertical and about its own middle
([HandController.turned_to_face](../src/board/hand_controller.gd), time constant `FACE_TIME` 0.12 s), so it stays upright. This is every canvas
standing in the room, a PDF included. Left alone: the two desks (a canvas on a physical surface, a curved desk), a canvas with its place locked,
one lying down or tilted over (its front within `FACE_UPRIGHT` of level), and one whose way two hands have set during this carry (it is
not turned back when one of them lets go). Guests see it turn, as they see it move (the held pose is what LiveOut sends).

When one hand is carrying a canvas (bar or empty-canvas drag, not a corner) and the **other hand pinches the same canvas** (touching it, its ray on the same canvas, or on no canvas):

| Hands do | Canvas does |
|---|---|
| Move together | translate with the midpoint |
| Rotate around each other | **yaw only** (about the vertical axis) |
| Move apart / together | **scale** by the distance ratio (ratio clamped 0.2 to 6, canvas scale 0.15 to 8). A **curved desk** keeps its outline: its *contents* zoom instead (section 10.3) |

Needs the hands > 4 cm apart to start. Letting go with one hand re-bases the other, so the canvas does not jump. A second hand on a *different* canvas is its own grab. The stylus's **front button counts as a pinch here too**: the nib is its pinch point, so a hand plus the stylus (front button held) turn and resize a canvas exactly like two hands, in either order. The hand that holds the stylus cannot pinch, so this is the way to do it with a stylus in hand.

### 9.3 No stylus, "Draw with a pinch" on (`finger_draw`)

| Hand | Role |
|---|---|
| **Right** | draws: the **pinch point** is the nib (so you must be within 12 cm of the canvas, like the stylus), pinching = pen-down, fixed pressure 0.7. It uses the *current tool* like the stylus (so Select works through the nib), but this hand no longer grabs canvases |
| **Left** | the normal pointing hand |

When the right hand touches or presses the menu it is captured and does not draw. A docked or absent stylus switches to this mode; with the setting off, no stylus means two pointing hands and nothing draws.

---

## 10. Placing a canvas

Dock: Add (+) > On a wall / On a table (or Home > Canvases). While placing, **the pen and hand controllers are suspended** (nothing else on the board reacts).

| | |
|---|---|
| Aim | stylus (nib position + `pen.dir`) if the stylus is tracked, else the first aiming hand's ray. The ghost snaps to the scanned wall or table (upright facing you, or flat), else to 0.85 m ahead |
| Confirm | **pen-down** (a new press) **or `pinch_down` of any free hand** |
| Cancel | stylus **back button** |

### 10.1 The desk: a canvas on a physical surface

Dock: Add (+) > **On my desk** (PC: **F**), or Home > Canvases > the desk button of an existing canvas ("lay it on the desk"; the same button frees it again).
[SurfaceController](../src/board/surface_controller.gd), card: [SurfaceCard](../src/ui/surface_card.gd).

**Finding it.** The stylus tip force sensor tells when the nib touches something. While the card is up (it stands on the dock; PC: right side), every press of the
nib (`pen.contact`) is a point of the surface: a **tap** is one point (the average position while pressed; a press under 0.12 s counts on release), a **rub** adds one every 2 cm. An amber dot
marks each point in the room, a plan on the card shows them and the area they span. A plane is fitted through all of them ([PlaneFit](../src/core/plane_fit.gd): least squares, so
any number of points is used, and any tilt: a wall works too). **Done** is available when at least 3 points span 5 cm in both directions and lie flat within 8 mm rms; the card says what is missing
("a few more points", "spread them out", "not flat enough") and shows how level the desk is. A ghost of the canvas shows on the fitted plane. While finding, the pen draws and grabs nothing. Back button, Esc or Cancel ends it.

**The canvas.** It lies in the plane at the middle of the points, facing the side your head is on, its top pointing away from you (up on a wall), at the size chosen in Add (S / M / L; it grows as you draw).
One undo step. It keeps a thin amber edge and "on the desk" in its title.

**Bound to the surface.** Whatever carries it (a pinch, the stylus front button, two hands, Q / E and the wheel on the PC) works on the canvas as for any other; the Board then puts the result back on the
surface (`FrameData.on_surface`, applied while it is carried and when it is let go): the origin slides to the nearest point of the plane, the canvas keeps facing along the plane's normal, the turn about the normal is kept, the
**scale is free**. So it moves around the desk, turns on it and grows or shrinks on it, and never leaves it. A corner still changes its extent. "Bring the canvas to me" refuses it with a message; the Home button frees it first.

**Following the desk.** Every touch of the nib on a desk canvas (within 4 cm of its plane, inside it) is a measurement, one per 3 cm of rubbing. After 4 new ones, the median height against the plane
is checked: more than 4 mm off, and the canvas is **moved** onto the surface (a single press on a book does nothing, the median ignores it). When 12 or more measurements span 25 cm, the plane is **refitted**; a tilt between 0.5 and 8 degrees is adopted
(the first guess from a few taps is a degree or so off; strokes across the canvas make it exact). These corrections are not undo steps (they are not edits) and make the anchor stale like any move.

| Tunable | |
|---|---|
| `PlaneFit` | `MIN_POINTS` 3 · `MIN_SPAN` 5 cm · `MAX_RMS` 8 mm |
| `SurfaceController` | `STEP` 2 cm · `TAP_S` 0.12 s · `NEAR` 4 cm · `TRACK_STEP` 3 cm · `TRACK_EVERY` 4 · `SHIFT_MIN` 4 mm · `TILT_MIN` 0.5° · `TILT_MAX` 8° · `TRACK_SPAN` 25 cm · `TRACK_MIN` 12 |

PC: **F** starts it; the mouse ray lands on the simulated room's table top or wall (the nib feels nothing in the air) and the held left button is the nib pressed.

### 10.2 A PDF canvas

A PDF is put down like an imported SVG: in front of you, facing you, at the size of its page (a portrait page 85 cm tall, a landscape one 110 cm wide; the next
one added within 90 s stands beside it). From then on it is a canvas: carried by its bar, resized at a corner, turned with two hands, locked, deleted (undo brings it back
with its drawings of every page).

| | |
|---|---|
| Page bar | hangs under the page of the PDF canvas you look at or work on (the nearest within 4 m, the active one first): first / previous / a slider over all pages / "3 / 12" / next / last. A press on a button is a press like any other (touch, or point and pinch / front button), so a guest with hands only can turn pages |
| Keys | Page Up / Page Down, Left / Right (no modifier) turn the page; Home / End go to the first / last. They work on the PC and from a Bluetooth keyboard, only while a PDF canvas is in view |
| Drawing | the tools work on the page like on any canvas, and a drawing belongs to the page shown when it was made; turning the page lets go of the selection |
| In a session | the owner's turn is everybody's; a guest who may not move canvases turns for themselves and gets "Back to the owner's page" on the bar (see SHARING.md §4) |
| Fading | the bar fades while the pen draws, like the dock |

---

### 10.4 A 3D model

A model ([model_controller.gd](../src/board/model_controller.gd), [model_gizmo.gd](../src/models/model_gizmo.gd)) stands in the room: a frame of kind
`model` whose origin is the middle of the model's bounds. It is put down in front of you (`MODEL_FRONT` 0.9 m, further for a big one), facing you,
at chest height (a model taller than 0.9 m stands on the floor). Its size: the size the file says, read as metres, when its longest side is
between 5 cm and 2 m (`MODEL_REAL`; glTF is in metres), else 40 cm along its longest side (`MODEL_FIT`). The first headset that loads it measures
it and sets that; until then a 30 cm box stands in.

The same verbs as on canvases. A pointer is the model's when it touches it (the pinch point or the nib within `MODEL_TOUCH` 3 cm of its box) or when
the model (or a handle) is nearer along its ray than any canvas; a canvas touched directly keeps the pointer. The HandController then leaves that
pointer alone (`HandController.skip`) and no stroke starts under the stylus.

| | |
|---|---|
| Tap (pinch or front button, let go within `MOVE_START`) | selects it: its handles and the model bar appear. A pinch on nothing at all, Esc, or the bar's close button lets go |
| Pinch the model and move | carries it (selected or not): 1:1 touching, geared by distance when pointing, like a canvas. No turning with one hand |
| Second pointer on it | the two turn it in any direction (the line between them) and resize it (their spread, about the point between them) |
| Move handles | arrow: along that axis (the point of the axis nearest the ray); square: in that plane (where the ray meets it); ball: freely |
| Rotate handles | ring: about its axis (the angle round the middle where the ray meets the ring's plane; a ray almost in that plane uses its point nearest the middle) |
| Scale handles | corner cube: evenly, about the middle (along the diagonal); axis cube: stretched along the model's own axis (`stretch`) |
| Bar | Move / Rotate / Scale, Snap (`SNAP_MOVE` 1 cm, `SNAP_TURN` 15°, `SNAP_SIZE` 1 cm), Room axes (move and turn along the room: up is up), Put down (onto the table or floor under it), Real size, Reset (upright, not stretched, its first size), Duplicate, lock its place, delete, close |
| Locks | `place_locked`: no carrying, moving or turning, still resized; `locked`: takes no pointer |

Handles are drawn over everything and keep their size on the eye: `GIZMO_SIZE` 0.02 per metre from the head, 5 mm to 6 cm; a ray within
1.9 handle sizes, a touch within 2.6 sizes + 12 mm, takes one. Every hold is one undo step through `Board.grabs` (the others see it move,
SHARING.md §4). On the PC: left or Shift+left click on a model or a handle, middle button carries it, the wheel scales it, Q / E turn it.

## 11. Feedback: what you see, hear and feel

### 11.1 Cursors, [hand_cursor.gd](../src/xr/hand_cursor.gd)

A ring on the target, facing the head, **the same apparent size at any distance** (clamped 6 to 50 mm). **No line is drawn from a hand to its ring**
(the stylus has one, below).

| Ring colour | Meaning |
|---|---|
| teal | on the **menu** |
| cyan | on an **item**: a grab selects / drags it |
| amber | on a **bar or corner** (or holding one): a grab picks the canvas up |
| white | on empty canvas |
| green, shrinks to 65 %, with a centre dot | **pressed** (pinching, or stylus front / tip) |
| centre dot only | touching the menu |

Plus, over any canvas a hand is on: four **corner dots** and the **bar capsule**. Idle 50 % white, 28 % when it is on an item, 100 % amber when they are what it is on or holds.

The stylus gets the same ring and chrome **while it points from a distance or holds something**, and a ring on the menu. Touching a canvas it
draws: its cursor is drawn *into the canvas* by the tool (dot + ring for brushes, red ring for erase, white dot for select, cross for shape)
and brightens as the nib approaches.

**The stylus's beam** ([stylus_ray.gd](../src/xr/stylus_ray.gd)), like the Quest's own controller ray: a line out of the nib along the
stylus (the aim pose's -Z), 4 mm wide with a faint dark edge so it reads on a white canvas or wall, never thinner than 1.5 px on the screen
(fainter instead). It starts 4 mm out of the nib, comes up to 80 % over 2 cm, and fades along its length:

| The stylus is | The beam |
|---|---|
| pointing at the menu, a canvas, a drawing, a corner or the bar of a panel | runs to the ring (stops at its edge), fading to 40 %, white at the nib and the ring's colour at the end |
| carrying a canvas or a panel from afar | runs to the canvas's plane / to the panel's bar |
| pointing at nothing | 0.5 m long, fading out |
| pressing (front button) | the ring's green over the whole beam |
| touching a canvas (within 12 cm), the menu or a bar, or the nib pressed on a real surface | none |

Home > Settings > **Pointing line** switches it off (`stylus_ray`). Hands have no beam.

### 11.2 Gloves, sounds and haptics

- **Ghost hands** (grey, fresnel-edged) show while a hand is tracked. They **hide while the nib is within 20 cm of a canvas** so they never cover a stroke. They are **pushed back** so a poking fingertip does not go through the menu.
- **Hands: click sounds** ([feedback.gd](../src/xr/feedback.gd), generated, no sound files): a tick (1.5 kHz, 26 ms) when a pinch closes, a softer lower one (1 kHz, 20 ms) when it opens. Not for the hand holding the stylus.
- **Stylus haptics** (amplitude / seconds):

| Event | Pulse |
|---|---|
| Menu press by stylus | 0.25 / 15 ms |
| Stroke begins | 0.15 / 10 ms |
| Erase hits something | 0.20 / 10 ms |
| Press on selection button | 0.40 / 20 ms |
| Front-button grab (item or canvas) | 0.30 / 20 ms |
| Front-button drop | 0.20 / 15 ms |
| Snapped to shape | 0.60 / 30 ms |
| Menu summoned by stylus | 0.40 / 30 ms |

Both the sounds and the haptics follow one setting: **More > Feedback** (`haptics`).

### 10.3 The curved desk

A desk canvas that is curved up into a wall. Add (+) > **Curved desk** (the same search for the desk as 10.1, which must be level: the normal's up part at least `Board.CURVE_LEVEL` 0.9),
Home > Canvases > **New curved desk**, or the curve button of a canvas that already lies on a level desk (it curves it, or flattens it again). [DeskBend](../src/core/desk_bend.gd).

**Lined up with the real desk.** Right after the desk is found (and after the curve button, and from Home > Canvases > **Line it up with my desk**), the desk card asks for two touches of
the nib ([SurfaceController.begin_align](../src/board/surface_controller.gd), [Board.align_curved](../src/board/board.gd)): **1** the desk's front edge, right in front of you, **2** the wall behind the desk, low
down (no wall: the desk's far edge). Each touch is where the nib was while pressed. The canvas then starts at the first point (on the desk's plane), runs towards the second, level with the desk, and
the distance becomes the edge-to-wall distance less the radius, so the upright part lies on the wall (a wall nearer than radius + 5 cm makes the radius smaller; nearer than `Board.ALIGN_MIN` 15 cm is refused and
the edge asked for again). The shown part is made long enough to reach `Board.WALL_ABOVE` 60 cm up the wall. What is drawn keeps its place on the canvas. One undo step; **Not now**, Esc or the back button leaves it as it was.

**Aligned to you (first guess).** Before it is lined up, the canvas's edge is put on the desk 15 cm in front of your chest (`Board.CHEST`), straight in front of the head, its top running away from you level along the desk. The
canvas is the *window* on the surface: `FrameData.size` / `offset` are the shown part in surface coordinates (default 1.0 x 1.5 m: your width, the flat part, the bend and the wall). What is drawn is
on the canvas as ever (same coordinates, same sizes); `bend_pan` is how far it has slid along the surface. A canvas that already had drawings is put so that they are in front of you on the flat part.

**The surface.** Flat on the desk up to `bend_at` from your edge (40 cm), then a quarter circle of `bend_radius` (12 cm) with its concave side to you, then straight up. It is a cylinder, so
the canvas is not stretched: a line keeps its length round the bend. Mapping canvas (x, y, height) to the room: u = x + pan.x, s = y + pan.y, and s along the surface ([DeskBend.to_node](../src/core/desk_bend.gd);
the shaders in [bend.gdshaderinc](../shaders/bend.gdshaderinc) do the same, with the same numbers). Everything that is drawn (ink, shapes, fills, text, the grid, the selection) is bent by its
material's vertex shader. For a long line to bend instead of cutting the corner, lines get a point every 8 mm of climb (`DeskBend.subdivide`, cheap, so the overlay can be drawn again every
frame), and fills and letters are cut into 8 mm strips once, when their mesh is built (`DeskBend.slice`); text is the font's outlines as geometry (`TextMesh`) because a `Label3D` is a flat quad. The
edge and the markers have a mesh of their own, drawn again only when the bend, the pan, the lit marker or how near a pointer is (in tenths) changes, not with the cursor. What slides out of the window is hidden. The pen, the hands, the mouse and the rays all use `FrameNode.to_local_point`, `to_world_point` and `ray_hit`,
which know the bend, so the nib at any part of the surface is at the canvas point under it, and a pointer at a distance is where its ray meets the surface.

**Moving the contents.** One pointer: a pinch (touching or pointing) on empty canvas, or the stylus front button, then a drag; the contents slide along the surface and the desk stays put
([HandController._slide](../src/board/hand_controller.gd)). *Touching*: step by step (so a hand that leaves the surface never makes them jump), by as far as the hand moved along the surface, plus
as far as it moved into the surface (or back out) times sin of how far round the bend it is. "The surface" is the part under the hand while it is within `InputTuning.BEND_SLIDE_NEAR` (6 cm) of it
(round the bend scaled by radius / the hand's distance from the bend's axis, so a hand traced along the surface keeps the page under it), else the part where the spot held is now. So on the desk
lifting the hand does nothing, on the wall pushing at it sends the contents up and pulling back brings them down, and a hand pushed on along the desk keeps sending them round the bend and up the
wall instead of stalling in it. *Pointing*: the spot the ray pinched stays under the ray (on the desk, round the bend, up the wall); a ray that misses the surface leaves them where they are.
What has slid off the shown part is hidden and is not picked (it would cover the bar). One undo step on release. A corner changes the shown part.

**Moving the desk.** A pinch or the front button on the **bar** in front of the desk carries the desk itself; it slides on the desk's plane (`FrameData.on_surface`) and gets a new anchor where
it is let go. A second pointer on the desk (bar or empty canvas, also while the first is sliding the contents, which then stop where they are) carries and turns it with the first, about the
desk's normal; the desk never scales (its bend and wall are in real metres). Moving the two apart or together **zooms the contents** instead
(the frame's `scale` is the zoom on a curved desk, `DeskBend.MIN_ZOOM` 0.25 to `MAX_ZOOM` 4): u = x * zoom + pan.x, s = y * zoom + pan.y, about the spot between
the two on the surface (under the pinch point touching, where the ray meets it pointing), which stays put. The outline, the bend and the markers keep their size
and place (the edge and markers are drawn in surface coordinates with `DeskBend.surface_material`). Geometry is cut finer above 2x (`DeskBend.cut_pitch`:
8 mm of canvas, halved per doubling past 2x, so a strip never covers more than 16 mm of the surface); the views are rebuilt only when that step changes.
Flattening keeps the zoom as the flat canvas's scale, and curving keeps a flat canvas's scale (clamped). One undo step. In a session the others see the contents slide and the markers move live (`p`, `ba`, `br` in the
grab message), as well as the desk moving.

**The markers.** Two round amber handles stand 4 cm outside the left edge, with a dashed line across: the **distance** marker where the flat part ends and the **radius** marker at the foot of the wall.
Touch one with the stylus tip (any tool), or pinch / front button on it; it lights up and says its number. The distance marker follows the nib's `y` on the desk (clamped 5 cm to 1.2 m); the radius marker
slides on the diagonal from the start of the bend (so the radius is the height of the nib, clamped 4 to 60 cm). Pointing from afar, the ray is met against the desk plane or the diagonal plane of the bend, not
the bent surface, so the marker does not run away from the pointer. One undo step on release; Home > Canvases shows both numbers with minus and plus (5 cm and 2 cm).

**Desk tracking** (10.1) only listens to touches on the flat part. A curved desk is only curved on the desk: freeing it from the desk (or "Free it and stand it upright") flattens it where it is first. A PDF canvas cannot be curved.
In a session the numbers are part of the canvas, so every headset shows the same bend (the desk's place in each room is the owner's, as for any canvas).

| Tunable | |
|---|---|
| `DeskBend` | `PITCH` 8 mm · `MIN_AT` 5 cm · `MAX_AT` 1.2 m · `MIN_RADIUS` 4 cm · `MAX_RADIUS` 60 cm · `DEFAULT_AT` 40 cm · `DEFAULT_RADIUS` 12 cm · `DEFAULT_SIZE` 1.0 x 1.5 m · `MIN_ZOOM` 0.25 · `MAX_ZOOM` 4 |
| `Board` | `CHEST` 15 cm · `CURVE_LEVEL` 0.9 · `CURVE_FRONT` 30 cm (where existing drawings are put) · `ALIGN_MIN` 15 cm · `WALL_ABOVE` 60 cm |
| `InputTuning` | `MARKER_SIDE` 4 cm · `MARKER_R` 2.4 cm · `MARKER_HIT` 5 cm · `BEND_SLIDE_NEAR` 6 cm |

---

## 12. Every tunable number

All in [input_tuning.gd](../src/core/input_tuning.gd) (`InputTuning`). The scripts alias the ones they use (`HandInput.PINCH_ON`,
`Board.CAPTURE` ...), so there is one place to change. `tests/test_hand_input.gd` pins the pinch thresholds.

| Group | Constants |
|---|---|
| Pinch | `PINCH_ON` 0.9 · `PINCH_OFF` 0.6 · `CLOSE_START` 0.35 · `CLOSE_CANCEL` 0.2 · `RISE_STEP` 0.003 · `JOINT_ON` 22 mm · `JOINT_FAR` 65 mm · `LOST_GRACE` 0.15 s · `PINCH_HISTORY_S` 0.6 · `PALM_UP_Y` 0.6 · `AIM_DOT_PROFILE` 0 · `AIM_DOT_JOINT` 0.1 |
| Desk | see 10.1: `PlaneFit` and `SurfaceController` constants (kept in those files: they are about measuring, not feel); the curved desk: 10.3 |
| Stylus | `TIP_ON` 0.035 · `TIP_OFF` 0.018 · `MID_ON` 0.09 · `MID_OFF` 0.05 · `NIB_SAMPLES` 45 (aligns the stylus model) · `PRESSURE_EXP` 0.75 · `STYLUS_FILTER` (2.2, 45) |
| Menu | `POKE_PRESS` 15 mm · `POKE_RELEASE` 30 mm · `POKE_BEHIND` 5 cm · `POKE_FRONT` 8 cm · `POKE_MARGIN` 1 cm · `MENU_RAY_REACH` 1.4 m · `HANDLE_Y` 3 cm · `HANDLE_NEAR` 7 cm · `HANDLE_RAY_R` 6 cm · `MENU_MAX_DIST` 2.5 m · `SCROLL_DEADZONE` 14 px · `SCROLL_SIDE` 1.6 · `GLOVES_OFF_NEAR` 0.2 m |
| Bringing the menu | `SUMMON_HOLD_S` 0.6 s · `PALM_SUMMON_DIST` 0.7 m · `PALM_REARM_S` 2 s · `SUMMON_AHEAD` 0.55 · `SUMMON_RIGHT` 0 · `SUMMON_UP` -0.3 · `SUMMON_STYLUS_CANVAS` 0.14 m |
| Pen on the board | `CAPTURE` 0.12 m · `SLACK` 0.6 m · `HOVER_RANGE` 0.28 m · `MIN_STEP` 0.9 mm · `HOLD_MOVE` 4 mm · `UNSNAP_MOVE` 12 mm (×2 in use) · `ERASE_R` 14 mm · `PICK_R` 13 mm · `HANDLE_HIT` 34 mm (outside the body; inside: `HANDLE_INSIDE` 12 mm · `HANDLE_INSIDE_MIN` 4 mm · `HANDLE_BODY_FRAC` 0.22) · `BTN_HIT` 28 mm · `LASSO_INSIDE` 0.6 · `SHAPE_TAP` 25 mm · `MIN_LINE` 2 cm · `hold_seconds` setting 0.55 s |
| Grabbing | `DIRECT_NEAR` 0.12 m · `DIRECT_STAY` 1.3 · `DIRECT_REACH` 1.6 · `REACH` 2.6 · `BAR_DROP` 7 cm · `BAR_HIT_W` 20 cm · `BAR_HIT_H` 7 cm · `CORNER_HIT` 7.5 cm · `PLANE_SLACK` 20 cm · `MOVE_START` 2 cm · `MAX_GAIN` 6 · `MIN_GAIN_DIST` 0.25 m · `MIN_CANVAS` 0.25 × 0.18 m · `TWO_HAND_MIN` 4 cm · `TWO_HAND_RATIO` 0.2 to 6 · `CANVAS_SCALE` 0.15 to 8 |
| 3D models | `MODEL_TOUCH` 3 cm · `MODEL_RAY_GROW` 1 cm · `GIZMO_SIZE` 0.02 / m (`GIZMO_SIZE_MIN` 5 mm, `GIZMO_SIZE_MAX` 6 cm) · `SNAP_MOVE` 1 cm · `SNAP_TURN` 15° · `SNAP_SIZE` 1 cm · `MODEL_FRONT` 0.9 m · `MODEL_FIT` 0.4 m · `MODEL_REAL` 0.05 to 2 (see 10.4) |
| Cursor | `CORNER_R` 14 mm · `BAR_LEN` 0.30 m · `BAR_R` 7.5 mm · `RING_R` 11 mm at 0.7 m, clamped `RING_MIN` 6 mm to `RING_MAX` 50 mm · `COL_*` colours (in `HandCursor`) |

Settings that change behaviour (Home > Settings and the popovers): `stylus_hand`, `finger_draw`, `haptics` (Feedback), `recognize`, `hold_seconds`, `ink_auto`, `ink_pause`, `smart_ink` (the pen notices writing), `ui_scale`, `ui_fade`, `tool`.

---

## 13. PC test build equivalents

[desktop_rig.gd](../src/desktop/desktop_rig.gd). The mouse is the stylus; the fly-camera is your head. Useful for tuning logic that is not about physical feel.

| Mouse / key | Stylus / hand equivalent |
|---|---|
| Left button | tip: pen-down (fixed pressure 0.75, real pressure from a tablet) |
| Shift + left | front button: **grab**, by touch (the mouse is always on the canvas plane): items, the bar, corners, empty canvas |
| Middle button | pinch (works anywhere over a canvas: `grab_anywhere`, and on a 3D model). Wheel scales the carried canvas or model, Q / E rotate it |
| Left / Shift + left on a 3D model | tap selects it; on a handle, drag it (section 10.4) |
| Right button + mouse, WASD | look, walk |
| Ctrl+Z / Ctrl+Y | undo / redo (the dock's buttons too; the back button has no key of its own) |
| 1 to 5 | Pen, Shapes, Write, Select, Erase (the dock shows them in the order Pen, Write, Shapes, Select, Erase) |
| C | place a canvas; F find the desk (section 10.1); T / Enter type text; B the brush; Tab hides the interface; Esc closes the topmost panel |

On the PC the panels float over the 3D view the same way (dock at the bottom, Home left, Assistant right, the canvas bars projected onto
their spot on the screen); the dock and the side panels have a grip (the dotted handle) to drag them, remembered in `panel_pos`.

Not simulated on the PC: pinch stabilisation, palm-up summon, the menu handle, poke, the second hand, grabbing from a distance, hand cursors, click sounds.
`res://tools/dev/sim_draw.tscn` drives this rig with synthetic mouse events; `tests/test_hand_input.gd` covers the pinch state machine, `tests/test_board.gd`
the touch / point grabs of hands and stylus and the back button, `tests/test_xr_rig.gd` the menu rules (capture, touch, handle, summon, several panels, the nib on a canvas bar), `tests/test_xr_panel.gd`
the panels' pointer mapping and see-through margins, `tests/test_ui_smoke.gd` the panels' flow rules.

---

## 14. Decisions and what stays different

Taken after the review of the earlier version, in the order the questions came up:

| # | Was | Now |
|---|---|---|
| 1, 2, 8 | Stylus grabbed directly (any canvas within 9 cm, never resized); hands grabbed by ray only; menu handle by proximity only | **One rule for hands, stylus and menu: touching is direct (1:1), pointing is geared.** The stylus front button does everything a pinch does, including resizing by a corner |
| 3, 4, 5 | Three definitions of "click"; the poke path ungated; any hover captured a pointer | **Touch or point.** Stylus at a distance clicks with the front button only; touching and the canvas gate apply to both; only touching or pressing captures |
| 6 | Undo only on the stylus back button, delayed 0.32 s for a double tap | Back button undoes **at once**; front + back = redo; the menu's undo / redo buttons are the hands' undo |
| 7 | A hand behaved as Select whatever the tool, undocumented | Kept, and stated: **hands arrange, the stylus marks** |
| 9 | Stylus hand cannot pinch or summon | Kept: with a stylus in hand, pinching is physically unreliable; documented in 3.1 |
| 10 | Two 0.8 s timers and two placements | One `SUMMON_HOLD_S` (0.6 s) and one place in front of you |
| 11 | No non-visual feedback for hands | A click sound on pinch close / open; one Feedback setting |
| 12 | Literals scattered through four files | One `InputTuning` file |

Deliberate differences that remain:

- **The stylus draws, hands do not.** Only a stylus tip (or the finger-draw setting) makes marks; hands are for arranging and the menu.
- **Redo has no long press.** An undo that fires at once cannot also turn into a redo when held (it would undo and redo itself), so redo is front + back, or the menu button.
- **A front press that begins while the nib is on the board is the tool's**, not a grab (it keeps shapes square).
- **At a canvas, the stylus is not offered the menu** (8.1, 6.1 rule 4).
