class_name ModelLighting
extends Node3D
## The light the 3D models are seen in. Everything else of the app is unshaded (ink, text, PDFs, the interface) and is not touched by it: the
## models (and the MX Ink model over the stylus) are on a render layer of their own, LAYER, and only these lights shine on that layer.
##   key   a warm light from above, over your left shoulder: shape and the main highlight
##   fill  a cool, weaker light from the right and lower: no side of a model goes black
##   rim   from behind and above: the outline stands out against the room
##   sky   soft light from all around and the reflections in shiny and metal surfaces (a neutral studio sky: never drawn, the room is
##         seen through it), set on the world's Environment by the rig (configure)
## The key, fill and rim turn with you (about the vertical, slowly), like a photographer's lights: whichever side of a model you look at
## is lit well. The `model_light` setting makes them softer or brighter. A model's soft shadow on the surface under it is ModelNode's.

const LAYER := 1 << 10                     # render layer 11: the models and the stylus model
const LEVELS := {"soft": 0.75, "studio": 1.0, "bright": 1.3}
const FOLLOW_S := 0.8                      # the lights turn after you with this time constant (s)

var key: DirectionalLight3D
var fill: DirectionalLight3D
var rim: DirectionalLight3D
var _yaw := 0.0
var _have_yaw := false


func _init() -> void:
	name = "ModelLighting"
	key = _light("Key", Color(1.0, 0.96, 0.9), 1.15, 48.0, 35.0)
	fill = _light("Fill", Color(0.86, 0.92, 1.0), 0.42, 18.0, -60.0)
	rim = _light("Rim", Color(1.0, 1.0, 1.0), 0.65, 30.0, 150.0)


func _ready() -> void:
	App.setting_changed.connect(func(k: String):
		if k == "model_light":
			_apply_level())
	_apply_level()


## A light that comes from `above` degrees over the horizon and from `left` degrees to the left of the viewer's back (0: from behind the
## viewer, over their head, onto what they look at; 180: from behind the model, towards the viewer), as seen by somebody facing -Z.
func _light(id: String, col: Color, energy: float, above: float, left: float) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.name = id
	l.light_color = col
	l.light_energy = energy
	l.set_meta("energy", energy)
	l.light_cull_mask = LAYER
	l.shadow_enabled = false
	l.light_specular = 0.8 if id == "Key" else 0.4
	l.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY           # (the sky stays as it is: its reflections are made once)
	# a light travels along its -Z: pitched down, then turned so that it comes from the left (travels to the right)
	l.rotation = Vector3(deg_to_rad(-above), deg_to_rad(-left), 0.0)
	add_child(l)
	return l


func _apply_level() -> void:
	var k: float = LEVELS.get(str(App.val("model_light")), 1.0)
	for l in [key, fill, rim]:
		(l as DirectionalLight3D).light_energy = float((l as DirectionalLight3D).get_meta("energy")) * k


## The lights turn after the head (about the vertical only).
func follow(head: Transform3D, dt: float) -> void:
	var f := -head.basis.z
	if Vector2(f.x, f.z).length() < 0.1:
		return
	var want := atan2(-f.x, -f.z)
	if not _have_yaw:
		_yaw = want
		_have_yaw = true
	else:
		_yaw += angle_difference(_yaw, want) * (1.0 - exp(-dt / FOLLOW_S))
	rotation = Vector3(0.0, _yaw, 0.0)


## The world's Environment, set up for the models: soft light from a neutral studio sky all around them, and its reflections. The sky is never
## drawn (the background stays what it was: the passthrough picture in the headset). Nothing unshaded is changed by it.
static func configure(env: Environment, budget: ModelBudget) -> void:
	if env.sky == null or not env.sky.has_meta("models"):
		env.sky = _studio_sky(budget)                      # (made once: the headset calls this whenever its session comes back)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY


static func _studio_sky(budget: ModelBudget) -> Sky:
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.62, 0.68, 0.78)
	mat.sky_horizon_color = Color(0.86, 0.86, 0.88)
	mat.sky_curve = 0.12
	mat.ground_bottom_color = Color(0.22, 0.21, 0.2)
	mat.ground_horizon_color = Color(0.62, 0.6, 0.57)
	mat.ground_curve = 0.06
	mat.sun_angle_max = 0.0
	var sky := Sky.new()
	sky.sky_material = mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64 if budget.radiance <= 64 else Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.set_meta("models", true)
	return sky


## Puts everything drawn under `node` on the models' layer (so these lights, and only these, shine on it).
static func use_layer(node: Node) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = LAYER
	for c in node.get_children():
		use_layer(c)
