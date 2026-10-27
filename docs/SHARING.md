# Sessions: several headsets, one whiteboard

One owner's headset (the **host**) and any number of guests' headsets (**clients**) on the same Wi-Fi see and edit the same canvases.
This document is the reference: what is sent, who decides what, every number. How to use it is in the README (*Running a session*).

Code: `src/net/` (`Session`, `SessionNet`, `DocSync`, `SharedSpace`, `LanDiscovery`, `LiveOut`), `src/board/peer_avatars.gd`,
`src/board/live_preview.gd`, `src/ui/session_page.gd` and `src/ui/align_card.gd`. Tests: `test_session` (an owner and two guests as three real
boards over real local connections), `test_live_preview` (the real pen controller drives strokes, drags, resizes, stencils, the eraser and a
carried canvas, and the others show them), `test_session_modes` (in the owner's room and elsewhere, §6), `test_doc_sync`, `test_session_net`, `test_shared_space`, `test_lan_discovery`. To look at it with your
own eyes: `tools/dev/sim_session.tscn` runs an owner that draws a slow stroke and a guest that photographs it half way (its header says how).

## 1. Who is who

| | |
|---|---|
| **Host** | The owner. Its document is the truth. It checks, applies and passes on every edit. It keeps working in its own document and saves it as usual, so what the guests drew is there afterwards. |
| **Client** | A guest. Works on a **copy of the shared room** (`Document.transient`: never written to their documents folder). Leaving or being removed brings their own document back. **Keep a copy** saves what is on the board as a document of their own. |
| **Shared room** | Only the room the host is in is shared (its canvases and their items). The host's other rooms, and every spatial anchor, stay on the host. If the host walks into another room or opens another document, everybody is sent that one. |

Nothing in a session needs every person to have a stylus: there is one MX Ink, the others point and pinch (§8).

## 2. Joining

1. The host switches the session on (Home > Session > *Start a session*): it listens on UDP **8190** (or the next free port up to 8199), announces
   itself on UDP **8191**, and shows a **four-digit code** (optional).
2. A guest's Home > Session lists the sessions it hears (beacon once a second; a session leaves the list 4.5 s after its last beacon), or
   *Join by address* takes `192.168.1.23` or `192.168.1.23:8190`. The code is asked for if the session has one.
3. `hello {version, name, code, device, place}` → `welcome {you, session, host, doc, room, can_edit, epoch}` → the guest sends `ready` → the host sends
   the snapshot (`snap` + `chunk`s) and `space`, and a `roster` to everybody. The guest's board then shows the copy, with the board put
   in front of them (§6).

Refusals (`refuse`): wrong code, session closed, session full (**40** guests), other protocol version, "wait". **5** wrong codes from one address
lock that address for **60 s**. A headset that connects and says nothing for **6 s** is cut off; one that says nothing for **15 s** is dropped.
Names are cleaned (control characters out, **24** characters) and made unique (`Ana`, `Ana (2)`). Each person gets a colour (10 of them).

The code and the plain-UDP transport are what keep the next studio out: they do not stop someone who is determined (nothing is
encrypted). Use a network you trust, and *Closed to new guests* once everybody is in.

## 3. The wire (`SessionNet`: ENet over UDP)

Four channels, so that a big thing in flight never holds up a small one:

| Channel | Carries |
|---|---|
| **control** (0) | `hello welcome refuse ready roster space ping pong status kicked ended` |
| **data** (1) | `snap chunk` (the document), `ops` (edits), `ack` |
| **file** (3) | `pdf? pdf pdfc pdf_no pdf_stop`: PDFs (below, §4) |
| **live** (2) | where everybody is looking and pointing: **10 Hz**, a compact binary packet (`0x50` one person's pose to the host, `0x51` everybody's to everybody, 58 bytes a person); and what everybody is in the middle of doing to the canvases (`0x60` a guest's to the host, `0x61` the host's, or one it passes on, to everybody: §5) |

All four are reliable. Live is too on purpose: ENet's congestion control throws unreliable packets away by the dozen even on an idle link
(measured: 60 % lost within seconds on loopback), and a late pose does no harm because only the newest per person is used.
Messages are dictionaries (`var_to_bytes`, **no objects**: a packet cannot carry a script); anything else, anything shorter than a value, anything
without a text `t` is dropped before the rest of the app sees it. A document is gzipped JSON in chunks of **96 KB**, at most **256 MB** unpacked.

A host that is told to remove or refuse someone waits **0.5 s** before cutting the connection, so that the message saying why gets there.
A session that ends tells everybody and waits **0.4 s**. A guest whose link drops (the headset slept, the Wi-Fi blinked) keeps what is on
the board and tries again every **3 s** for **120 s**, then gets a fresh snapshot (anything edited while disconnected is lost).

## 4. Editing

**State, not operations.** `DocSync` listens to the document's own signals (`item_added/changed/removed`, `frame_…`), remembers *which ids* changed,
and sends their *current state* (`ops {frames, items, gone_frames, gone_items}`). Undo, imports, the AI's accepted suggestions and every other
way of editing the document are carried without any of them knowing: they all end in those signals. A batch that arrives twice or late
does no harm. A batch is applied frames first, then items, then removals; at most **20 000** items per batch; malformed entries are skipped.
What belongs to a device (a frame's spatial anchor and its pose when made) is never sent and never taken: the host re-anchors a frame a guest moved.

**One order for everybody.** A guest shows its own edit at once and sends it; until the host has answered (`ack {seq}`), news about the same
ids from others is held back. The host handles each guest batch as one step: pass on everything before it, apply it, pass it on to all but
that guest, answer it. So everybody ends with the host's order; when two people change the same thing at once, one of them wins whole (no
half-and-half), and every headset agrees which (tested).

**What a guest may do**, checked by the host on every batch (a modified app gains nothing):

| Setting (Home > Session, host) | Off means |
|---|---|
| *Guests can draw and write* (and per guest, the pen button in the roster) | nothing a guest does reaches the document; their own board does not even start a stroke (`History.read_only`) |
| *Guests can add and move canvases* | adding, removing, renaming, restyling and moving canvases is the owner's |
| a canvas the owner **locked** | its items and the canvas itself cannot be changed by a guest, and only the owner can lock or unlock it |
| *Closed to new guests* | nobody else can join; those in stay |

A refused edit is taken back: the host's answer carries the true state of those ids, the guest's board shows it again, and says why (at most every 4 s).

### PDFs: files and pages

A canvas that shows a PDF is an ordinary canvas that also says *which* PDF (`FrameData.pdf`, the first 32 hex digits of the SHA-256 of the file), *which page*
(`page`), how many pages it has (`pdf_pages`, so every headset can say "3 / 12" before it has the file) and how wide the page is put down (`pdf_width`).
Drawings on it carry the page they were drawn on (`Item.page`). All of that travels like everything else (frames and items as state), so the
document of a session never contains a PDF. The file itself goes on the **file channel**, once, to the headsets that need it (`PdfShare`):

1. A guest's board shows a canvas whose PDF it does not have: `PdfLibrary.want` → `pdf? {id}`.
2. The owner answers only for an id that a canvas **of the shared room** shows (else `pdf_no`: *not part of the session*), one transfer at a time per guest:
   `pdf {id, n, size, name}`, then `pdfc {id, i, d}` in pieces of 96 KB, paced at 6 MB/s per guest.
3. The guest refuses a file bigger than its own limit **before** taking it (`pdf_stop`): a Quest 2 takes 48 MB, a Quest 3 64 MB, and the canvas on that headset
   says *This PDF is too big for this headset*. It checks that the bytes are the file whose id it asked for (a damaged or swapped file is dropped), keeps it with its
   PDFs (marked as a session copy: the newest six are kept when a session ends) and makes the pages itself.

Every headset therefore draws the page from the same file at its **own budget** (`PdfBudget`: a Quest 2 flattens curves coarser, keeps smaller pictures and makes
no page ahead; the page looks the same, with fewer triangles). The pages themselves are never sent.

**Turning pages.** The owner's turn is the frame's `page`, so it reaches everybody and everybody who follows shows it (and its drawings). A guest who may not move canvases
turns pages **for themselves** (`Document.view_pages`, never saved, never sent): their drawings take the page they are looking at, a chip on the page bar ("Back to the owner's
page") returns them, and the owner's later turns do not pull them away. A guest allowed to move canvases turns the page for everybody. Undo never turns a page back
(`History` keeps the page the canvas is on).

### 3D models: files

A 3D model is a frame of kind `model` that says *which* model (`FrameData.model`, the first 32 hex digits of the SHA-256 of the file as the library keeps it:
a .glb, .gltf, .obj, or a .zip of a model and the files it uses), how far it is stretched along its own axes (`stretch`) and its bounds in the file's units
(`model_box`, measured by the first headset that loads it and then everybody's, so a headset that cannot load it still shows a box of the right size).
Like a PDF, the file goes on the **file channel**, once, to the headsets that need it (`ModelShare`): `mdl? {id}`; the owner answers only for a model a
frame of the shared room shows (else `mdl_no`), `mdl {id, n, size, name, ext}` then `mdlc` pieces of 96 KB at 6 MB/s per guest; a guest refuses a file
over its own limit first (`mdl_stop`: a Quest 2 takes 48 MB, a Quest 3 96 MB), checks the content id, and keeps the newest six session copies.

Each headset then loads the model itself within its own budget (`ModelBudget`: a Quest 2 takes up to 400 000 triangles and 1024 px pictures, a Quest 3
1.5 million and 2048 px; both make simpler versions of detailed meshes for a distance). A model over a headset's limit is not shown there: a box of its
size says *too detailed for this headset*, and the other headsets are not held up. Moving, turning, resizing and stretching go through `Board.grabs`,
so the others see the model move while it is held (`LiveOut` sends its pose, scale and stretch) and get the result when it is let go. Adding,
moving and deleting models follow *Guests can add and move canvases*. Protocol 3 (a headset with an older build is told to update).

## 5. Presence

Every **0.1 s** each headset sends its head pose and its **pointer**: the stylus if there is one, otherwise the index fingertip of a tracked hand
(*pressed* = the pinch). The host passes everybody's on. Poses older than **2.5 s** are not drawn. `PeerAvatars` draws, smoothed:
a name tag over the head, the pointer's tip (bigger while pressed) with a **14 cm** ray, and for somebody who is not in the same real room a soft
orb with a cone for the gaze. Two headsets lined up on the same real room (both *points*, §6) see the real people, so there they get the tag and
pointer only.

### Edits in progress

What somebody is in the middle of is shown to the others while it happens (`LiveOut` sends, `LivePreview` shows; nothing of it is in the document):

| While a person is | the others see |
|---|---|
| drawing or writing | the stroke growing point by point, in its brush, colour and width |
| holding the pen still so that the stroke snaps | the shape it will become, not the stroke under it |
| dragging items, or turning / scaling a group by its handles | the items following the hand |
| resizing, turning or reshaping one shape, or moving a line's end | that shape as it changes |
| dragging a stencil out | the stencil's shape as it grows |
| passing the eraser over things | those things gone (not yet deleted) |
| carrying a canvas, with a hand, a pinch or the front button | the canvas moving and changing size, in its room (a canvas on a desk stays on it) |

Not shown: the selection loop, typing, the assistant's suggestions (they are one person's own until accepted).

**How.** About **12 times a second** (`LiveOut`) each headset asks its pen controllers what they are doing (`PenController.live_view`) and sends only what
changed: new points of a stroke (up to 400 a message), the transform items are shown with, the shape being reshaped as an item dictionary. A drag that
stands still is repeated every **0.4 s** so that the others know it is going on. The host shows a guest's and passes it on to the others; it
ignores guests who may not edit, so a view-only guest can not put anything on anybody's canvas.

**The hand-over to the real edit.** A stroke is given the id its item will have *when it starts* (a recognised or snapped shape takes that id too),
so the preview goes the moment the item with that id exists, and not before: there is no gap and no double drawing. Previews of drags and
reshapes remember the item they started from and stand down as soon as the document replaces it, so a late message can not move something twice
or undo the real edit. A canvas that was put down is held where it was put until the document has it (at most **1 s**). A stroke that ends and
did not become an item (thrown away) goes at once; one that did waits at most **1 s** for its item.

**Going away.** A preview that is not kept up goes by itself: a stroke after **8 s** without a point (a pen can rest), anything else after
**1.5 s**. Everything of a person goes when they leave, are removed, or the session ends; a guest that reconnects starts clean.

**Safety.** Everything that arrives is somebody else's data: types are checked, at most **1024** points a message and **2000** ids, only canvases
that exist, only plain shapes for a reshape, only finite numbers, a scale only between 0.15 and 8, and an unknown brush is the default one.

## 6. One room for everybody: the shared space `P` (`SharedSpace`)

Every headset has its own tracking space, so they disagree about where a canvas is until they agree on a frame. Everything on the wire is in
**P**; each headset holds **F**, the pose of P in its own tracking space (`local = F * p`). Poses and the shared room's origin (`room_p`) are sent as `F⁻¹ * …`
and shown as `F * …`. The host's `room_p` is re-sent when it moves by more than **2 mm or 0.15°** (checked 4 times a second).
F only turns about *up* and slides (a headset's floor is level), so the floors agree whatever each headset thinks the floor height is.

### Two places to be in: `together` and `apart`

Each guest says where they are (`place`, sent in `hello` and in `status`, listed in the `roster`, remembered in the setting `session_place` and in
`session_resume`). The owner needs no choice: it is the room. Both can be in one session, and a guest can change their mind at any time
(`Session.set_place`). What is shared is the same in both (§4, §5); what differs is **where the board is for that guest**:

| | `together`: in the owner's real room | `apart`: somewhere else |
|---|---|---|
| `align_mode` | `none` until lined up, then `points` | `here` from the moment the document is in |
| The canvases | **Not shown** (`room_world()` is null, the board says `searching`) until the guest has touched the owner's two places **and** the owner has (`peers[1].align == "points"`), so a canvas is never drawn off its real spot | In front of the guest at once, 1.1 m away, facing them |
| Joining | The card for touching the two places comes up by itself (`_start_lining_up`) | Nothing to do |
| Presence | Nothing is sent or drawn while there is no shared space (`in_shared_space()`): a pose in the wrong frame would put the person in the wrong place. Afterwards: tag and pointer (they are the real person) | Orb with a gaze, tag and pointer |
| The owner aligns again | A guest lined up on the old epoch is asked to check (same two points: nothing to do) | The board **stays where it is**: `F` is re-based (`F' = F * room_p_old * room_p_new⁻¹`) so the owner touching points for somebody else never moves it |
| The owner goes back to the room's own space | Waits (nothing shown) until the owner lines up again | Stays where it is |

Touching the two places (`_set_align("points")`) means being in the owner's room, so it sets `place = together`; *Board in front of me* (`use_here`)
sets `apart`. `place` is therefore never out of step with `align_mode` (`together`: `none | points`; `apart`: `here`). The owner is told when
somebody joins or switches to `together` while they are not lined up (a toast, and the dock's session button turns amber: `needs_attention()`).
The host sends the new space before the roster that says the owner is lined up (`align_point`, `align_reset`), so a guest never sees one without the other.
Only a guest's own claim is taken (`together | apart`; anything else is `apart`); it grants nothing: it changes only what that guest sees.

**points** (lined up on the real room): everybody touches the **same two real places, in the same order** (two corners of a table), with the stylus
tip (held **0.12 s**, averaged) or by pinching on them (held **0.35 s**, averaged). The frame those two points make (origin at the first, x along
the floor to the second, y up) is the same physical frame for everybody, so each headset's F is that frame as seen from its own tracking
space. Rules: at least **60 cm** apart along the floor (yaw error = point error / distance: 5 mm over 1.5 m is 0.2°, 3 cm of a pinch is more, so
**use points far apart**); the owner does it too; the points are marked in the room for **20 s** afterwards to check by eye. On the
headset F is held by a **spatial anchor**, so it follows if the room is relocalised or the headset recentred (not verified on a headset).
Until the owner aligns to points, the owner's F is the **shared room's own frame** (held by the owner's room anchor), not the owner's
tracking space: so the owner recentring, re-localising or restarting changes nothing on the wire and moves nobody's board.
If the owner aligns again the session gets a new `epoch`; guests lined up on the old one are told to check (same two points: nothing to do).

**here** (`apart`, the default on joining): F stands the session's main canvas **1.1 m** in front of the guest's
head, facing them (a flat canvas facing away from the side they stand on, so it reads upright); heights are kept. With no canvas yet the
guest stands where the owner stands. *Board in front of me* does it again. That F is held by a spatial anchor too, so the board stays
where it was put in the guest's room when the headset recentres or is taken off; a reconnect (or the owner sharing the same room again)
keeps it; only a different room shared by the owner is put in front again.

**After a restart.** Each headset saves the session it is in (`session_resume` in its settings) whenever something about it changes, and clears
it when the session is ended or left on purpose. At the next start the owner's headset waits (up to 120 s with the headset on) for the session's
room and starts the session again with the same id, code, permissions and `epoch`; if it was aligned to points, it tells nobody where the room is
until the anchor of the two points is found (15 s, else it goes back to the room's own frame and the guests who aligned by points are asked
to align again). A guest's headset joins the session again (same address and code) and, if the session, its epoch and its room are the same,
takes back its alignment from its anchor (15 s, else the board is put in front of them, or, for somebody in the owner's room, nothing is shown until
they touch the two places again). Guests who are still running simply reconnect.
*Keep a copy* gives the copy a room anchor of the guest's own where the board was, so it opens there later.

Tested: two headsets with different tracking spaces, aligned on two points, see every canvas on the same real place (within 2 mm) and a
stylus pointing at a real spot shows up on that spot for each of them (`test_session`). `test_session_modes`: an owner with two guests in the
room (one with a stylus, one with pinches) and one elsewhere, all in different tracking spaces: nothing shown to a guest in the room until
both have lined up (either may go first), then the same real spot within 2 mm for both; the guest elsewhere's board does not move by
a millimetre while the owner lines up, goes back and lines up again; people in the room are drawn as people, those elsewhere as orbs;
switching in both directions; a cancelled card never shows the board in the wrong place.

## 7. Discovery (`LanDiscovery`)

A beacon is a small JSON packet `{m: "mrw-session", v: 1, id, session, host, doc, port, pin, locked, n}` to `255.255.255.255:8191` and to the
`x.y.z.255` of every IPv4 network the headset is on, once a second. The listener believes it only for the right magic, version and a port
of 1024 or more, and takes the address from the packet, not from what it says. Only one listener per machine can bind the port; a second
one is told no and the typed address is the way in. Guest Wi-Fi and some routers block broadcast or isolate clients: then only the typed address
works, and if that does not either, the network is blocking it.

### Files from outside: the web page and Telegram

The web page's uploads and the Telegram bot (`TelegramBridge`) bring files into the headset that runs them. On the **owner's** headset that is all it
takes: the PDF or model goes into the library, a canvas or model frame names it, and the guests are given the file as above. A **guest's** headset
cannot give a file to the owner (files only travel owner to guest), so a PDF or model a guest's bot receives is kept in that guest's library and not
put up as a canvas the others could not load; the bot says so. An SVG becomes ordinary canvases and items, which DocSync carries both ways, so a guest's
SVG reaches everybody when *Guests can add and move canvases* is on. Text sent to a bot is put down with the placement tool and replicates like typed text.

## 8. Devices

* **Quest 2 and Quest 3 together** work: nothing in the session depends on the model. The Android export already declares Quest 2 support. A Quest 2
  starts at the *performance* render quality unless the user has chosen one (about half the GPU of a Quest 3).
* **3D models** have a budget per device (section 4): a Quest 2 shows smaller, simpler models than a Quest 3 and says so in the room for one it cannot.
* **One stylus** (the MX Ink): the others have only their hands. Hands point (their fingertip is their pointer), arrange (select, drag, resize)
  and can draw by pinching on a canvas (*Draw with a pinch*, offered in Home > Session), and align by pinching. Whoever holds the stylus still has the
  front button as a pinch.
* The PC build can join or host as well (mouse as the pointer), which is how the session was tested on one machine: `--host=Name --code=1234`
  and `--join=127.0.0.1 --code=1234 --guest=Ben` (see `main.gd`).

## 9. What is not verified

Everything above runs and is tested on a PC (three boards in one process, and three copies of the app on one machine). **Not run on a headset:**
that Horizon OS lets the app listen on UDP 8190 and receive broadcasts on 8191, what a Quest 2 does with the rest of the app, the anchor that holds F,
and how well two touched points line two real headsets up (the maths is exact; the nib and the hand tracking are not). First things to check:
a guest can join by typed address; the two aligned headsets agree on a real corner within a centimetre or two (and a guest in the owner's room, who sees
nothing until both have lined up, finds that clear rather than broken: the card, the amber session button and the toast are what tell them);
a guest elsewhere finds the board comfortably in front of them (1.1 m is a walk from a drawing arm's length); the log lines `[session]` say what happened;
after restarting the owner's app (and then a guest's) the session comes back with every board where it was.

Not built: Meta's *shared spatial anchors* (would line the headsets up without touching points, and
need the app registered with Meta), encryption, a guest re-joining after the owner changed the code, several owners.
