class_name WebPages
extends RefCounted
## The HTML of the pages ExportServer serves. Plain strings in, plain strings out: the server hands over a snapshot of the document
## ({doc, rev, here, total, items, groups: [{id, name, here, frames: [{id, name, items, w, h}]}]}) and a list of saved files
## ([{rel, ext, size, modified}]). Styling and behaviour are in WebAssets (stylesheet, script, icons).


static func h(s: String) -> String:
	return s.xml_escape(true)


static func u(s: String) -> String:
	return s.uri_encode()


static func ic(name: String) -> String:
	return "<svg class=ic><use href='#i-%s'/></svg>" % name


static func plural(n: int, one: String, many: String = "") -> String:
	return "%d %s" % [n, one if n == 1 else (many if many != "" else one + "s")]


## Wraps a page body in the common frame: top bar, icon sprite, toasts, the stylesheet and the script.
static func shell(title: String, body: String, doc_name: String = "", rev: String = "", signed_in: bool = true, page: String = "") -> String:
	var v := WebAssets.VERSION
	var out := "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
	out += "<meta name=color-scheme content='light dark'><title>%s - MR Whiteboard</title>" % h(title)
	out += "<link rel=icon type='image/svg+xml' href='/assets/logo.svg'><link rel=stylesheet href='/assets/app.css?v=%d'>" % v
	out += "<script>try{var t=localStorage.getItem('mrw-theme');if(t)document.documentElement.setAttribute('data-theme',t)}catch(e){}</script>"
	out += "</head><body data-rev='%s'%s>" % [h(rev), " data-page='%s'" % h(page) if page != "" else ""]
	out += WebAssets.SPRITE
	out += "<header class=topbar><div class=topbar-in><a class=brand href='/'><img src='/assets/logo.svg' alt=''>MR Whiteboard</a>"
	if doc_name != "":
		out += "<span class=crumb>/ <b>%s</b></span>" % h(doc_name)
	out += "<span class=spacer></span>"
	if signed_in:
		out += "<a class='btn btn-ghost btn-sm' href='/live' title='Watch the canvases as they are drawn'>%s<span>Live view</span></a>" % ic("eye")
		out += "<a class='btn btn-ghost btn-sm' href='/ai' title='Work on a canvas with an AI: keys, models, questions'>%s<span>AI</span></a>" % ic("spark")
		out += "<span class=live title='Live connection to the headset'><i></i><span>Connected</span></span>"
	out += "<button class='btn btn-ghost btn-sm' id=theme title='Light / dark'>%s</button>" % ic("moon")
	if signed_in:
		out += "<a class='btn btn-ghost btn-sm' href='/logout' title='Sign out'>%s<span>Sign out</span></a>" % ic("logout")
	out += "</div></header><main class=wrap>%s</main>" % body
	out += "<div id=banner class=banner>The headset made changes <button class='btn btn-primary' id=banner-refresh>%s Refresh</button></div>" % ic("refresh")
	out += "<div id=toasts></div><script src='/assets/app.js?v=%d' defer></script></body></html>" % v
	return out


# ------------------------------------------------------------------------------------------------ sign in, messages

static func login(error: String = "") -> String:
	var b := "<div class=auth><form class=auth-card method=post action='/login' autocomplete=off>"
	b += "<div class=badge>%s</div><h1>Enter the access code</h1>" % ic("lock")
	b += "<p>It is shown in the headset: <b>Home &rarr; Share</b> (the last button on the toolbar).</p>"
	b += "<input class=pin id=pin name=pin inputmode=numeric pattern='[0-9]*' maxlength=6 placeholder='------' autocomplete=one-time-code required autofocus>"
	if error != "":
		b += "<div class=err role=alert>%s</div>" % h(error)
	b += "<button class='btn btn-primary'>Open my canvases</button>"
	b += "<div class=hint>Only people who can see the headset's screen know this code. It changes every time sharing is switched on.</div></form></div>"
	return shell("Sign in", b, "", "", false)


static func message(title: String, text: String, signed_in: bool = true) -> String:
	var b := "<div class=auth><div class=auth-card><h1>%s</h1><p>%s</p><a class='btn btn-primary' href='/'>Back to the canvases</a></div></div>" % [h(title), h(text)]
	return shell(title, b, "", "", signed_in)


# ------------------------------------------------------------------------------------------------ dashboard

static func dashboard(snap: Dictionary, files: Array, pdfs: Array = []) -> String:
	var groups: Array = snap.groups
	var b := "<section class=head><div><p class=eyebrow>Document</p><h1>%s</h1>" % h(snap.doc)
	b += stats(snap)
	b += "</div><div class=actions>"
	b += "<button class='btn btn-primary' onclick=\"document.getElementById('file').click()\">%s Upload PDF or SVG</button>" % ic("upload")
	b += "<a class='btn btn-primary' href='/live'>%s Live view</a>" % ic("eye")
	b += "<a class=btn href='/ai'>%s AI assistant</a>" % ic("spark")
	if int(snap.total) > 0:
		b += "<a class=btn href='/all.zip'>%s Download all</a><a class=btn href='/all'>%s Gallery</a>" % [ic("download"), ic("image")]
	b += "</div></section>"
	b += "<label class=drop id=drop tabindex=0><span class=badge>%s</span><span><strong>Drop PDF or SVG files here</strong>" % ic("upload")
	b += "<span>or click to choose. A <b>PDF</b> is kept in the headset and put in front of you to read, page by page, and to draw on. An <b>SVG</b> becomes a new canvas of real shapes, strokes and text you can select and change.</span></span>"
	b += "<input type=file id=file accept='.pdf,application/pdf,.svg,image/svg+xml' multiple></label><div id=uploads class=uploads></div>"
	b += pdf_panel(pdfs)
	b += library(snap)
	b += files_panel(files)
	b += "<p class=foot>Shared live from your headset. Changes you make here appear there at once.</p>"
	return shell(str(snap.doc), b, str(snap.doc), str(snap.rev))


static func stats(snap: Dictionary) -> String:
	var s := "<div class=stats id=stats data-swap>"
	s += "<span class=chip><b>%d</b> %s</span>" % [snap.total, "canvas" if int(snap.total) == 1 else "canvases"]
	s += "<span class=chip><b>%d</b> %s</span>" % [(snap.groups as Array).size(), "room" if (snap.groups as Array).size() == 1 else "rooms"]
	s += "<span class=chip><b>%d</b> items</span></div>" % snap.items
	return s


static func library(snap: Dictionary) -> String:
	var groups: Array = snap.groups
	if int(snap.total) == 0:
		return "<div id=library data-swap><div class=empty><div class=badge>%s</div><h2>No canvases yet</h2><div>Draw on one in the headset, or upload an SVG above.</div></div></div>" % ic("grid")
	var b := "<div id=library data-swap><div class=toolbar><div class=tabs>"
	b += "<button class='tab on' data-room=''>All<small>%d</small></button>" % snap.total
	for g in groups:
		b += "<button class=tab data-room='%s'>%s<small>%d</small></button>" % [h(g.id), h(g.name), (g.frames as Array).size()]
	b += "</div><button class='btn btn-ghost btn-sm' data-act=select-all>Select all</button>"
	b += "<label class=search>%s<input id=q type=search placeholder='Search canvases' autocomplete=off></label></div>" % ic("search")
	b += "<div id=bulk class=bulk><span id=bulk-n></span><span class=spacer></span>"
	b += "<button class='btn btn-sm' data-act=bulk-zip>%s Download selected</button>" % ic("download")
	b += "<button class='btn btn-sm btn-danger' data-act=bulk-delete>%s Delete</button>" % ic("trash")
	b += "<button class='btn btn-sm btn-ghost' data-act=bulk-clear>Clear</button></div>"
	for g in groups:
		b += "<section class=room data-room='%s'><div class=room-h>%s<h2>%s</h2>%s" % [h(g.id), ic("room"), h(g.name), "<span class=tag>here now</span>" if g.here else ""]
		b += "<div class=links><a class='btn btn-ghost btn-sm' href='/room/%s'>View all</a><a class='btn btn-ghost btn-sm' href='/room/%s.zip'>%s Zip</a></div></div><div class=grid>" % [u(g.id), u(g.id), ic("download")]
		for f in g.frames:
			b += card(f, g.id)
		b += "</div></section>"
	b += "</div>"
	return b


static func card(f: Dictionary, room_id: String) -> String:
	var id := u(f.id)
	var nm := h(f.name)
	var sub := "empty" if int(f.items) == 0 else plural(int(f.items), "item")
	var b := "<article class=card data-id='%s' data-name='%s'>" % [h(f.id), nm]
	b += "<label class=pick title=Select><input type=checkbox aria-label='Select %s'><span></span></label>" % nm
	b += "<a class=thumb href='/view/%s'><img loading=lazy alt='%s' src='/svg/%s.svg'></a>" % [id, nm, id]
	b += "<div class=card-body><div class=card-title title='%s'>%s</div><div class=card-sub>%s &middot; %.1f &times; %.1f m</div></div>" % [nm, nm, sub, float(f.w), float(f.h)]
	b += "<div class=card-actions><a class=icon-btn href='/view/%s' title=View>%s</a>" % [id, ic("eye")]
	b += "<a class=icon-btn href='/svg/%s.svg?dl=1' title='Download SVG'>%s</a>" % [id, ic("download")]
	b += "<button class=icon-btn data-act=rename data-name='%s' title=Rename>%s</button><span class=spacer></span>" % [nm, ic("pencil")]
	b += "<button class='icon-btn danger' data-act=delete data-name='%s' title=Delete>%s</button></div></article>" % [nm, ic("trash")]
	return b


## The PDFs kept in the headset: each can be put in front of the viewer again, opened here, downloaded or removed.
static func pdf_panel(pdfs: Array) -> String:
	if pdfs.is_empty():
		return "<div id=pdfs data-swap></div>"
	var b := "<section class=panel id=pdfs data-swap><div class=panel-h>%s<h2>PDF documents</h2><span>Kept in the headset. Everybody in a session gets them when they are put down.</span></div>" % ic("file")
	b += "<table><thead><tr><th>Name</th><th class='num hide'>Pages</th><th class='num hide'>Size</th><th></th></tr></thead><tbody>"
	for e in pdfs:
		var id := str(e.id)
		b += "<tr data-pdf='%s'><td><div class=file>%s<span>%s</span><span class=ext>pdf</span></div></td>" % [h(id), ic("file"), h(str(e.name))]
		b += "<td class='num hide'>%d</td><td class='num hide'>%s</td><td class=acts>" % [int(e.pages), size_text(int(e.size))]
		b += "<button class='btn btn-sm' data-act=pdf-show data-id='%s' title='Put it in front of you in the headset'>%s Show in headset</button>" % [h(id), ic("eye")]
		b += "<a class=icon-btn href='/pdf/%s.pdf' target=_blank rel=noopener title='Open it here'>%s</a>" % [u(id), ic("image")]
		b += "<a class=icon-btn href='/pdf/%s.pdf?dl=1' title=Download>%s</a>" % [u(id), ic("download")]
		b += "<button class=icon-btn data-act=pdf-rename data-id='%s' data-name='%s' title=Rename>%s</button>" % [h(id), h(str(e.name)), ic("pencil")]
		b += "<button class='icon-btn danger' data-act=pdf-delete data-id='%s' data-name='%s' title=Delete>%s</button></td></tr>" % [h(id), h(str(e.name)), ic("trash")]
	b += "</tbody></table></section>"
	return b


static func files_panel(files: Array) -> String:
	if files.is_empty():
		return "<div id=files data-swap></div>"
	var b := "<section class=panel id=files data-swap><div class=panel-h>%s<h2>Saved on the headset</h2><span>Files made with the Export buttons in the app</span></div>" % ic("file")
	b += "<table><thead><tr><th>File</th><th class='num hide'>Size</th><th class='num hide'>Saved</th><th></th></tr></thead><tbody>"
	for f in files:
		var rel := u(f.rel).replace("%2F", "/")
		b += "<tr><td><div class=file>%s<span>%s</span><span class=ext>%s</span></div></td>" % [ic("file"), h(f.rel), h(f.ext)]
		b += "<td class='num hide'>%s</td><td class='num hide'>%s</td><td class=acts>" % [size_text(int(f.size)), date_text(int(f.modified))]
		b += "<a class=icon-btn href='/files/%s' title=Download>%s</a>" % [rel, ic("download")]
		b += "<button class='icon-btn danger' data-act=delete-file data-rel='%s' title=Delete>%s</button></td></tr>" % [h(f.rel), ic("trash")]
	b += "</tbody></table></section>"
	return b


static func size_text(bytes: int) -> String:
	if bytes < 1024:
		return "%d B" % bytes
	if bytes < 1024 * 1024:
		return "%.0f KB" % (bytes / 1024.0)
	return "%.1f MB" % (bytes / 1048576.0)


static func date_text(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


# ------------------------------------------------------------------------------------------------ live view

## The live view: an empty frame that the script (WebAssets.JS, "live view") fills from /api/live and keeps up to date. Nothing on it
## changes the document.
static func live(doc_name: String) -> String:
	var b := "<section id=lv class=lv data-mode=grid>"
	b += "<div class=lv-bar><div><p class=eyebrow>Live from the headset</p><h1 id=lv-name>%s</h1><div class=stats><span class=chip id=lv-stat>Connecting...</span></div></div>" % h(doc_name)
	b += "<div class=lv-ctl>"
	b += "<label class=lv-follow title='Show the canvas that is being drawn on, whichever it is'><input type=checkbox id=lv-follow> Follow the pen</label>"
	b += "<div class=seg id=lv-mode><button data-mode=grid class=on>Grid</button><button data-mode=focus>One canvas</button></div>"
	b += "<div class=seg id=lv-bg><button data-bg=auto class=on title='As the canvas looks in the headset'>As in headset</button><button data-bg=white>White</button><button data-bg=dark>Dark</button><button data-bg=none>Clear</button></div>"
	b += "<div class=seg id=lv-lang title='Translate the text on the canvases, on this PC (Chrome or Edge 138 or newer)'><button data-lang='' class=on>Original</button><button data-lang=es title='Castilian Spanish'>Espa&ntilde;ol</button><button data-lang=eu title=Basque>Euskara</button><button data-lang=fr title=French>Fran&ccedil;ais</button></div>"
	b += "<button class='btn btn-sm' id=lv-full title='Full screen'>%s</button>" % ic("fit")
	b += "</div></div><p class=lv-note id=lv-tr-note hidden></p>"
	b += "<div class=lv-nav id=lv-nav><button class='btn btn-sm' id=lv-prev title='Previous (left arrow)'>%s Previous</button>" % ic("left")
	b += "<b id=lv-cur></b><button class='btn btn-sm' id=lv-next title='Next (right arrow)'>Next %s</button></div>" % ic("right")
	b += "<div id=lv-body></div>"
	b += "<div class=empty id=lv-empty hidden><div class=badge>%s</div><h2>No canvases yet</h2><div>Place a canvas in the headset: it appears here as soon as it is there.</div></div>" % ic("grid")
	b += "</section>"
	return shell("Live view", b, doc_name, "", true, "live")


# ------------------------------------------------------------------------------------------------ AI assistant

## The AI assistant's page: an empty frame that the script (WebAssets.JS, "AI assistant") fills from /api/ai/state. API keys typed
## here go to the device and are never sent back (the page only learns their last four characters).
static func ai(doc_name: String) -> String:
	var b := "<section id=ai class=ai>"
	b += "<div class=head><div><p class=eyebrow>AI assistant</p><h1>Work on a canvas with an AI</h1>"
	b += "<div class=stats><span class=chip id=ai-stat>Connecting...</span></div></div></div>"
	b += "<div class=ai-grid><section class=panel><div class=panel-h>%s<h2>Ask about a canvas</h2></div><div class=ai-body>" % ic("spark")
	b += "<label class=lbl for=ai-canvas>Canvas</label><select id=ai-canvas class=field></select>"
	b += "<div class=ai-acts id=ai-acts></div>"
	b += "<label class=lbl for=ai-q>Or ask in your own words</label>"
	b += "<textarea id=ai-q class='field ta' rows=3 maxlength=4000 placeholder='For example: turn my notes into a flow chart. What is missing here? Add a legend.'></textarea>"
	b += "<div class=row><button class='btn btn-primary' id=ai-send>%s Ask</button><span class=spacer></span>" % ic("spark")
	b += "<button class='btn btn-ghost btn-sm' id=ai-forget title='Forget the earlier questions about this canvas'>New conversation</button></div>"
	b += "<div id=ai-status class=ai-status></div>"
	b += "<div id=ai-reply class=ai-reply hidden><div class=ai-meta id=ai-meta></div><div class=ai-say id=ai-say></div></div>"
	b += "<div id=ai-layers class=ai-layers></div></div></section>"
	b += "<section class=panel><div class=panel-h>%s<h2>Models and keys</h2></div><div class=ai-body>" % ic("lock")
	b += "<div id=ai-provs class=ai-provs></div>"
	b += "<label class=chk><input type=checkbox id=ai-picture> Send a picture of the canvas with its description (lets the model read sketches and handwriting)</label>"
	b += "<label class=chk><input type=checkbox id=ai-note> Put answers in words on the canvas as a note</label>"
	b += "<p class=hint>Your key goes from this page to the headset over your Wi-Fi and is kept only in the app's settings there; this page never shows it again. "
	b += "The headset sends each question, with a description and a picture of that one canvas, straight to the provider you chose; it is billed to your key.</p>"
	b += "</div></section></div></section>"
	return shell("AI assistant", b, doc_name, "", true, "ai")


# ------------------------------------------------------------------------------------------------ gallery and viewer

static func gallery(snap: Dictionary, title: String, groups: Array, zip_href: String) -> String:
	var b := "<a class=back href='/'>%s All canvases</a><div class=vhead><h1>%s</h1><a class=btn href='%s'>%s Download zip</a></div><div class=gal>" % [ic("left"), h(title), zip_href, ic("download")]
	for g in groups:
		if groups.size() > 1:
			b += "<div class=room-h>%s<h2>%s</h2>%s</div>" % [ic("room"), h(g.name), "<span class=tag>here now</span>" if g.here else ""]
		for f in g.frames:
			var id := u(f.id)
			b += "<article class=card data-id='%s' data-name='%s'><div class=gal-h><b>%s</b><a class=icon-btn href='/view/%s' title=View>%s</a>" % [h(f.id), h(f.name), h(f.name), id, ic("eye")]
			b += "<a class=icon-btn href='/svg/%s.svg?dl=1' title='Download SVG'>%s</a></div>" % [id, ic("download")]
			b += "<div class=full><img loading=lazy alt='%s' src='/svg/%s.svg'></div></article>" % [h(f.name), id]
	b += "</div>"
	return shell(title, b, str(snap.doc), str(snap.rev))


static func viewer(snap: Dictionary, f: Dictionary, prev_id: String, next_id: String, bg: String) -> String:
	var id := u(f.id)
	var q := "" if bg == "white" else "?bg=" + bg
	var qd := "?dl=1" + ("" if bg == "white" else "&bg=" + bg)
	var b := "<a class=back href='/'>%s All canvases</a>" % ic("left")
	b += "<div class=vhead><h1 id=vtitle>%s</h1>" % h(f.name)
	if prev_id != "":
		b += "<a class='btn btn-sm' id=prev href='/view/%s%s' title='Previous (left arrow)'>%s Previous</a>" % [u(prev_id), q, ic("left")]
	if next_id != "":
		b += "<a class='btn btn-sm' id=next href='/view/%s%s' title='Next (right arrow)'>Next %s</a>" % [u(next_id), q, ic("right")]
	b += "<a class='btn btn-primary' href='/svg/%s.svg%s'>%s Download SVG</a>" % [id, qd, ic("download")]
	b += "<button class=btn data-act=rename data-id='%s' data-name='%s'>%s Rename</button>" % [h(f.id), h(f.name), ic("pencil")]
	b += "<button class='btn btn-danger' data-act=delete data-id='%s' data-name='%s'>%s Delete</button></div>" % [h(f.id), h(f.name), ic("trash")]
	b += "<div class=vbar><div class=seg>"
	for opt in [["white", "White"], ["dark", "Dark"], ["none", "Transparent"]]:
		b += "<a class='%s' href='/view/%s?bg=%s'>%s</a>" % ["on" if opt[0] == bg else "", id, opt[0], opt[1]]
	b += "</div><div class=seg><button id=zout title='Zoom out'>%s</button><button id=zv disabled>100%%</button><button id=zin title='Zoom in'>%s</button><button id=zfit title='Fit'>%s</button></div>" % [ic("minus"), ic("plus"), ic("fit")]
	b += "<a class='btn btn-sm btn-ghost' href='/svg/%s.svg%s' target=_blank rel=noopener>Open the raw SVG</a></div>" % [id, q]
	b += "<div class=stage><img id=vimg class='bg-%s' alt='%s' src='/svg/%s.svg%s'></div>" % [bg, h(f.name), id, q]
	return shell(str(f.name), b, str(snap.doc), str(snap.rev))
