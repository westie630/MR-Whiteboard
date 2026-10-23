class_name WritingDetector
extends RefCounted
## Is this ink writing or a drawing? Decided from the shape of the strokes alone, before anything is sent to a recogniser:
##  - is_mark(): one stroke drawn while writing that is clearly not a letter: a line (an underline, a strike, an arrow's shaft), a box
##    or ring around the words, something far taller than the writing. Write mode keeps these as drawings instead of reading them.
##  - group_score(): strokes drawn with the pen that look like words: letters of a similar height, side by side in reading order,
##    curvy, wider than tall. The pen then offers to turn them into text.
## Everything is measured in metres (canvas units times the canvas's scale).

const MIN_LETTER := 0.008                  # writing is at least this tall (median stroke height)...
const MAX_LETTER := 0.3                    # ...and at most this
const DOT := 0.006                         # a stroke smaller than this is a dot (i, j, a full stop): it says nothing
const LINE_ALONE := 0.15                   # with no writing yet, a straight stroke this long is a line
const LINE_K := 2.6                        # with writing, a straight stroke longer than this many letter heights is a line
const STRAIGHT := 0.94                     # chord / length from which a stroke is straight
const BOX_K := 2.4                         # a closed stroke this many letter heights wide (and BOX_TALL tall) goes round the words
const BOX_TALL := 1.6
const BOX_ALONE := 0.28                    # ...or, with no writing yet, this big
const TALL_K := 4.0                        # a stroke this many letter heights tall is not a letter
const TALL_ALONE := 0.25
const LOOP_K := 1.6                        # among pen strokes, a closed loop this many letter heights wide and tall is a drawing
const SUGGEST := 0.55                      # group_score from which the pen offers to convert
const AUTO := 0.8                          # ...and converts by itself when asked to


## Measurements of one stroke: {rect, w, h, diag, length, chord, straight, closed, ratio, turns_x, turns_y, dot, a, b}.
static func features(it: Item, scale: float = 1.0) -> Dictionary:
	var n := it.point_count()
	var pts := PackedVector2Array()
	for i in n:
		var p := it.pt(i)
		pts.append(Vector2(p.x, p.y) * scale)
	return features_of(pts)


static func features_of(pts: PackedVector2Array) -> Dictionary:
	var n := pts.size()
	if n == 0:
		return {"rect": Rect2(), "w": 0.0, "h": 0.0, "diag": 0.0, "length": 0.0, "chord": 0.0, "straight": 1.0, "closed": false, "ratio": 1.0,
			"turns_x": 0, "turns_y": 0, "dot": true, "a": Vector2.ZERO, "b": Vector2.ZERO}
	var r := Rect2(pts[0], Vector2.ZERO)
	var length := 0.0
	for i in n:
		r = r.expand(pts[i])
		if i > 0:
			length += pts[i].distance_to(pts[i - 1])
	var diag := r.size.length()
	var chord := pts[0].distance_to(pts[n - 1])
	# direction reversals along x and y, on a resampled path (jitter below the step is ignored)
	var step := maxf(maxf(r.size.y, r.size.x) * 0.08, 0.0015)
	var tx := 0
	var ty := 0
	var sx := 0
	var sy := 0
	var last := pts[0]
	for i in range(1, n):
		var d := pts[i] - last
		if d.length() < step:
			continue
		last = pts[i]
		var nx := int(signf(d.x)) if absf(d.x) > step * 0.35 else 0
		var ny := int(signf(d.y)) if absf(d.y) > step * 0.35 else 0
		if nx != 0:
			if sx != 0 and nx != sx:
				tx += 1
			sx = nx
		if ny != 0:
			if sy != 0 and ny != sy:
				ty += 1
			sy = ny
	return {"rect": r, "w": r.size.x, "h": r.size.y, "diag": diag, "length": length, "chord": chord,
		"straight": chord / maxf(length, 1e-6), "closed": n > 4 and chord < 0.22 * diag and length > 1.8 * diag,
		"ratio": length / maxf(diag, 1e-6), "turns_x": tx, "turns_y": ty, "dot": diag < DOT, "a": pts[0], "b": pts[n - 1]}


## A stroke drawn while writing that is not a letter. `letter_h` is the height of the writing around it (0: nothing written yet).
static func is_mark(f: Dictionary, letter_h: float) -> bool:
	if bool(f.dot):
		return false
	var line_len := LINE_ALONE if letter_h <= 0.0 else maxf(LINE_K * letter_h, 0.06)
	if float(f.straight) > STRAIGHT and float(f.length) > line_len:
		return true
	if bool(f.closed):
		if letter_h <= 0.0:
			if float(f.diag) > BOX_ALONE:
				return true
		elif float(f.w) > BOX_K * letter_h and float(f.h) > BOX_TALL * letter_h:
			return true
	if letter_h <= 0.0:
		return float(f.h) > TALL_ALONE
	return float(f.h) > TALL_K * letter_h


## The small stroke right after a line (an arrowhead, a tick at its end) belongs to the line.
static func attached(f: Dictionary, line_a: Vector2, line_b: Vector2, line_len: float) -> bool:
	if bool(f.dot) or float(f.diag) > line_len * 0.45:
		return false
	var reach := maxf(line_len * 0.2, 0.02)
	var r: Rect2 = (f.rect as Rect2).grow(reach)
	return r.has_point(line_a) or r.has_point(line_b)


## The typical height of the letters among these features (dots left out), or 0.
static func letter_height(fs: Array) -> float:
	var hs: Array = []
	for f in fs:
		if not bool(f.dot):
			hs.append(maxf(float(f.h), float(f.w) * 0.35))     # a flat stroke (a dash, the bar of a t) counts by its width
	if hs.is_empty():
		return 0.0
	hs.sort()
	return float(hs[hs.size() / 2])


## How much these strokes (in the order they were drawn) look like a line or two of writing: 0 (a drawing) .. 1 (clearly words).
static func group_score(items: Array, scale: float = 1.0) -> float:
	var fs: Array = []
	for it in items:
		fs.append(features(it as Item, scale))
	return score_features(fs)


static func score_features(fs: Array) -> float:
	var body: Array = fs.filter(func(f): return not bool(f.dot))
	if body.is_empty():
		return 0.0
	var med := letter_height(body)
	if med < MIN_LETTER or med > MAX_LETTER:
		return 0.0
	for f in body:
		if is_mark(f, med):
			return 0.0
		# a closed loop much bigger than the letters both ways is a box or a ring in a drawing (an o, an a, a capital D are not)
		if bool(f.closed) and float(f.w) >= LOOP_K * med and float(f.h) >= LOOP_K * med:
			return 0.0
	if body.size() == 1:
		# one stroke: joined-up handwriting goes back and forth along the line many times
		var f0: Dictionary = body[0]
		if int(f0.turns_x) >= 4 and float(f0.w) > 1.8 * float(f0.h) and float(f0.ratio) > 2.5:
			return 0.7
		return 0.0
	var bb: Rect2 = body[0].rect
	for f in body:
		bb = bb.merge(f.rect)
	var similar := 0.0
	var curvy := 0.0
	for f in body:
		var h := float(f.h)
		if h <= 2.6 * med and maxf(h, float(f.w)) >= 0.2 * med:
			similar += 1.0
		if float(f.ratio) > 1.3 or int(f.turns_x) + int(f.turns_y) >= 2:
			curvy += 1.0
	similar /= body.size()
	curvy /= body.size()
	# reading order: each stroke starts no further left than a little before where the previous one was (crossings and accents
	# step back a bit; a new line starts far left, but lower)
	var forward := 0.0
	for i in range(1, body.size()):
		var prev: Rect2 = body[i - 1].rect
		var cur: Rect2 = body[i].rect
		var new_line := cur.get_center().y < prev.position.y - med * 0.4
		if new_line or cur.get_center().x > prev.position.x - med * 0.6:
			forward += 1.0
	forward /= maxf(body.size() - 1, 1)
	var wide := bb.size.x / med
	var lines := bb.size.y / med
	var score := 1.0
	score *= clampf((similar - 0.5) / 0.35, 0.0, 1.0)
	score *= clampf((forward - 0.45) / 0.35, 0.0, 1.0)
	score *= clampf((curvy - 0.15) / 0.35, 0.0, 1.0)
	score *= clampf(wide / 1.6, 0.0, 1.0)
	score *= 1.0 if lines <= 4.5 else clampf(1.0 - (lines - 4.5) / 3.0, 0.0, 1.0)
	score *= 1.0 if body.size() >= 3 else 0.8
	return score
