class_name AiPrompts
extends RefCounted
## The words the app sends to the model: one system prompt that explains the canvas and the answer format, and one request per
## button. The user only picks a button (or types / says a question); the app writes the prompt.

## [id, button label, icon, the request, draws?]. "draws" requests put their result in the suggestion layer; the others answer in words.
const ACTIONS := [
	["opinion", "Opinion", "text", "Give me your honest opinion of this canvas: what works, what is unclear or missing, and the one or two changes that would help most. Answer in words only: leave add, change and remove empty.", false],
	["improve", "Improve it", "convert", "Improve this drawing. Put the improvements in add, change and remove: for example clearer or corrected labels, missing steps or links, a better layout, and neat shapes in place of rough freehand ones where the meaning is clear. In say, list briefly what you changed.", true],
	["continue", "Continue", "plus", "Continue this: add the next logical parts (steps, ideas, branches, examples) in the same style, placed beside or below what is there, connected where that makes sense. In say, tell me briefly what you added.", true],
	["tidy", "Tidy up", "grid", "Tidy the layout: align and evenly space the items and straighten the connectors, mostly with change (move and resize). Keep every meaning and every word as it is. In say, one sentence on what you did.", true],
	["explain", "Explain", "doc", "Explain in plain words what this canvas shows, as you understand it, in a few sentences. Answer in words only: leave add, change and remove empty.", false],
	["check", "Find mistakes", "check", "Check this canvas for mistakes: spelling, wrong facts, gaps in the logic, arrows that point the wrong way. List them in say. Correct wording mistakes with change; do not redraw anything else.", true],
]

const SYSTEM := """You are a thoughtful, practical collaborator working with the user on a whiteboard canvas in mixed reality (the user wears a headset and draws with a stylus).

You get the canvas as JSON: its items with short ids, in centimetres, x to the right and y DOWN, (0, 0) at the top-left of the drawn area. Boxes and text are given by their top-left corner (x, y) and size (w, h); lines by their ends (x1, y1, x2, y2) and, when glued to shapes, by "from" and "to"; freehand strokes by a few points along them. Items marked "selected" are the ones the user means: focus on those. A picture of the canvas may come too: it shows exactly the area of the JSON (it does not show text; read the text from the JSON). Freehand strokes are often handwriting or sketches: use the picture to understand them.

Answer with exactly one JSON object and nothing else:
{"say": "what you tell the user", "add": [], "change": [], "remove": []}

say: plain text, no markdown, short paragraphs or lines starting with "- ". Keep it under 120 words unless asked for more: it is read in the headset.
add: new items, each one of
  {"type": "shape", "shape": "rect" | "rrect" | "diamond" | "para" | "doc" | "cyl" | "ellipse" | "triangle" | "hex" | "pent" | "star" | "rarrow", "x": .., "y": .., "w": .., "h": .., "label": "words inside", "color": "#rrggbb", "fill": "#rrggbb"}
    (rect = process box, rrect = start / end, diamond = decision, para = data, doc = document, cyl = database)
  {"type": "text", "text": "..", "x": .., "y": .., "size": "h1" | "h2" | "h3" | "body" | "small", "color": "#rrggbb"}
  {"type": "arrow" | "line" | "darrow" | "elbow", "from": "id", "to": "id"}  (or "x1", "y1", "x2", "y2" for free ends; elbow = right-angled connector)
  {"type": "stroke", "points": [[x, y], ...], "closed": false, "width_mm": 3, "color": "#rrggbb"}  (for drawings no shape can express)
  Give a new item an "id" such as "n1" when an arrow must connect to it.
change: {"id": "existing id", and only the fields to change: x, y, w, h, label, text, size, color, fill, from, to}
remove: ids of items to delete.

Rules:
- Draw (add, change, remove) only when the request asks for drawing or changes. Your drawing is shown as a suggestion layer over the canvas that the user accepts or discards, so make it complete and tidy.
- Match the canvas: similar sizes, the same kinds of shapes, colours that suit how it looks (omit color to use the canvas's main ink colour). Use the label of a shape for the words inside it rather than a separate text.
- Do not put new items on top of existing ones unless they replace them (then remove or change the old ones). Space for new things is to the right of or below the drawn area; the canvas grows.
- Never invent a mistake to correct, and say plainly when something is unclear."""


## "AI text": words written to be put on a canvas, so the answer is the text itself, not the JSON of the assistant.
const TEXT_SYSTEM := """You write short text for a whiteboard that the user reads in a mixed-reality headset. Answer with only the text to put on the canvas: plain text, no markdown, no quotation marks around it, no introduction and no closing remark. Use short lines or lines starting with "- ". Keep it under 80 words unless the user asks for more."""


## Tidy the model's text for the canvas: no code fence, no markdown marks, no stray quotation marks around all of it.
static func clean_text(text: String) -> String:
	var t := text.strip_edges()
	if t.begins_with("```"):
		t = t.trim_prefix("```")
		var nl := t.find("\n")
		t = t.substr(nl + 1) if nl >= 0 else t
		t = t.trim_suffix("```").strip_edges()
	var lines := PackedStringArray()
	for line in t.split("\n"):
		var l := line.rstrip(" \t")
		if l.begins_with("#"):
			l = l.lstrip("#").strip_edges()
		l = l.replace("**", "").replace("__", "")
		if l.begins_with("* "):
			l = "- " + l.substr(2)
		lines.append(l)
	t = "\n".join(lines).strip_edges()
	if t.length() > 2 and t.begins_with("\"") and t.ends_with("\"") and t.count("\"") == 2:
		t = t.substr(1, t.length() - 2)
	return t


static func action(id: String) -> Array:
	for a in ACTIONS:
		if a[0] == id:
			return a
	return []


static func label_of(id: String) -> String:
	var a := action(id)
	return str(a[1]) if not a.is_empty() else "Question"


## The user message for a request: what was asked, then the canvas.
static func request(action_id: String, question: String, brief_json: String, has_picture: bool, selected: int) -> String:
	var a := action(action_id)
	var ask := str(a[3]) if not a.is_empty() else question.strip_edges() + "\n(Draw only if this asks for drawing or changes.)"
	var parts := PackedStringArray([ask])
	if selected > 0:
		parts.append("I have selected %d item%s: they are marked \"selected\"." % [selected, "" if selected == 1 else "s"])
	parts.append("The canvas%s:\n%s" % [" (the picture shows it too)" if has_picture else "", brief_json])
	return "\n\n".join(parts)
