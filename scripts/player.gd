extends CharacterBody3D
class_name MoonPlayer
## First-person astronaut for the spherical Moon.
##
## "Up" is the radial direction of the planet, and moon.gd keeps this body aligned to it and sets
## up_direction every physics frame. Gravity comes from moon.gravity_vector (1.62 m/s^2, radial), so
## walking around the globe, jumping and falling all follow the curvature of the sphere.
##
## Lunar feel:
##  - weak gravity -> long, slow, floaty jumps (and a bounding "lope" if you keep jumping while running)
##  - suit + dust -> slow acceleration, long braking, and NO traction in the air (momentum is conserved)
##  - steep slopes slow you down uphill, very steep ones are not walkable
##  - slow, wide camera bob, a soft landing dip, and ballistic dust kicked up by steps and landings
##
## Controls: WASD / arrows move, Shift bound (run), Space jump (hold to keep hopping),
## mouse look, Esc releases the mouse, click recaptures it.

@export var moon: MoonPlanet

@export_group("Look")
@export var mouse_sensitivity := 0.0022
@export var max_pitch_deg := 88.0

@export_group("Suited locomotion")
@export var walk_speed := 1.6            # m/s, a careful walk
@export var run_speed := 4.2             # m/s, the Apollo "lope" top speed
@export var ground_accel := 3.2          # m/s^2 on regolith (low traction)
@export var ground_brake := 2.4          # m/s^2 when you let go of the keys
@export var air_steer := 0.12            # m/s^2 of (almost no) control in the air
@export var jump_speed := 2.3            # m/s -> ~1.6 m high, ~2.8 s in the air at 1.62 m/s^2
@export var slope_limit_deg := 38.0      # steeper than this you cannot stand or walk
@export var uphill_penalty := 0.55       # fraction of speed lost walking straight up a max slope

@export_group("Camera")
@export var eye_height := 1.6
@export var fov := 78.0
@export var bob_amount := 1.0
@export var landing_dip := 1.0

@export_group("Dust")
@export var dust_enabled := true

var _pitch := 0.0
var _dip := 0.0
var _bob_phase := 0.0
var _bob_weight := 0.0
var _h_speed := 0.0
var _stride := 0.0
var _dust: Array[CPUParticles3D] = []
var _dust_i := 0
var _hud: Label

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(slope_limit_deg)
	floor_snap_length = 0.15          # small, so you can leave the ground over crests (low gravity)
	floor_stop_on_slope = true
	head.position.y = eye_height
	camera.fov = fov
	camera.current = true
	if moon == null and get_parent():
		moon = get_parent().get_node_or_null("MoonPlanet") as MoonPlanet
	_build_dust()
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_object_local(Vector3.UP, -event.relative.x * mouse_sensitivity)
		var lim := deg_to_rad(max_pitch_deg)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -lim, lim)
		head.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _down(a: Key, b: Key = KEY_NONE) -> bool:
	return Input.is_physical_key_pressed(a) or (b != KEY_NONE and Input.is_physical_key_pressed(b))


func _physics_process(delta: float) -> void:
	var up := up_direction
	var g: Vector3 = moon.gravity_vector if moon else -up * 1.62
	var was_floor := is_on_floor()

	# Heading and strafe directions, flattened into the local tangent plane of the sphere.
	var fwd := -global_basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-8:
		fwd = up.cross(global_basis.x)
	fwd = fwd.normalized()
	var right := fwd.cross(up).normalized()

	var input := Vector2(
		float(_down(KEY_D, KEY_RIGHT)) - float(_down(KEY_A, KEY_LEFT)),
		float(_down(KEY_W, KEY_UP)) - float(_down(KEY_S, KEY_DOWN)))
	var wish := right * input.x + fwd * input.y
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	var top := run_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	if input.y < 0.0:
		top *= 0.6

	if was_floor:
		var speed := top
		var n := get_floor_normal()
		var slope := acos(clampf(n.dot(up), -1.0, 1.0))
		var downhill := n * n.dot(up) - up
		if downhill.length_squared() > 1e-6 and wish.length_squared() > 1e-6:
			var uphill := clampf(-wish.normalized().dot(downhill.normalized()), 0.0, 1.0)
			speed *= 1.0 - uphill_penalty * uphill * clampf(slope / maxf(floor_max_angle, 0.01), 0.0, 1.0)
		var v_h := velocity - up * velocity.dot(up)
		var rate := ground_accel if wish.length_squared() > 1e-4 else ground_brake
		v_h = v_h.move_toward(wish * speed, rate * delta)
		velocity = v_h + g * delta                  # tiny pull keeps the floor contact stable
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity += up * jump_speed
	else:
		velocity += g * delta                       # ballistic: curved by the radial gravity field
		if wish.length_squared() > 1e-4:
			velocity += wish * air_steer * delta
			var vh := velocity - up * velocity.dot(up)
			var lim := maxf(run_speed, _h_speed)
			if vh.length() > lim:
				velocity -= vh - vh.normalized() * lim

	var fall_speed := -velocity.dot(up)
	move_and_slide()

	var rv := get_real_velocity()
	_h_speed = (rv - up * rv.dot(up)).length()

	var now_floor := is_on_floor()
	if now_floor and not was_floor and fall_speed > 0.4:
		_dip = maxf(_dip, clampf(fall_speed * 0.05 * landing_dip, 0.0, 0.3))
		_puff(fall_speed * 1.6)
		_stride = 0.0
	elif now_floor and _h_speed > 0.2:
		_stride += _h_speed * delta
		var len := _stride_length()
		if _stride >= len:
			_stride -= len
			_puff(0.4 + _h_speed * 0.5)


func _stride_length() -> float:
	return lerpf(0.8, 2.4, clampf(_h_speed / maxf(run_speed, 0.1), 0.0, 1.0))


func _process(delta: float) -> void:
	# Slow, wide lunar bob: bigger and floatier the faster you go, gone in the air.
	var moving := is_on_floor() and _h_speed > 0.15
	_bob_weight = lerpf(_bob_weight, 1.0 if moving else 0.0, 1.0 - exp(-8.0 * delta))
	if moving:
		_bob_phase = fposmod(_bob_phase + _h_speed / _stride_length() * TAU * delta, TAU * 2.0)
	var k := clampf(_h_speed / maxf(run_speed, 0.1), 0.0, 1.0)
	var amp := lerpf(0.012, 0.075, k) * bob_amount * _bob_weight
	_dip = lerpf(_dip, 0.0, 1.0 - exp(-2.5 * delta))
	head.position = Vector3(cos(_bob_phase * 0.5) * amp * 0.45, eye_height + sin(_bob_phase) * amp - _dip, 0.0)
	_update_hud()


# ---------------------------------------------------------------- dust
func _build_dust() -> void:
	if not dust_enabled:
		return
	var mesh := SphereMesh.new()
	mesh.radius = 0.04
	mesh.height = 0.08
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.50)
	mat.roughness = 1.0
	mesh.material = mat
	for i in 4:
		var p := CPUParticles3D.new()
		p.top_level = true
		p.mesh = mesh
		p.emitting = false
		p.one_shot = true
		p.explosiveness = 1.0
		p.amount = 18
		p.lifetime = 3.0                 # long, because particles fly ballistically in 1.62 m/s^2
		p.local_coords = false
		p.spread = 65.0
		p.initial_velocity_min = 0.2
		p.initial_velocity_max = 1.2
		p.scale_amount_min = 0.6
		p.scale_amount_max = 1.6
		p.gravity = Vector3.ZERO
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		_dust.append(p)


# Kick up a puff of regolith at the feet. No air, so it flies on a clean parabola and falls slowly.
func _puff(strength: float) -> void:
	if _dust.is_empty():
		return
	var p := _dust[_dust_i]
	_dust_i = (_dust_i + 1) % _dust.size()
	var up := up_direction
	p.global_position = global_position
	p.direction = up
	p.gravity = moon.gravity_vector if moon else -up * 1.62
	p.initial_velocity_max = 0.5 + clampf(strength, 0.0, 6.0) * 0.5
	p.restart()
	p.emitting = true


# ---------------------------------------------------------------- HUD
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_hud = Label.new()
	_hud.position = Vector2(16, 12)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_hud)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(center)
	var dot := ColorRect.new()
	dot.color = Color(1, 1, 1, 0.5)
	dot.custom_minimum_size = Vector2(3, 3)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(dot)


func _update_hud() -> void:
	if _hud == null or moon == null:
		return
	var p := Vector3(
		float(moon._off[0]) + global_position.x,
		float(moon._off[1]) + global_position.y,
		float(moon._off[2]) + global_position.z)
	var r := maxf(p.length(), 1.0)
	var lat := rad_to_deg(asin(clampf(p.y / r, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(p.x, p.z))
	_hud.text = "speed    %.1f m/s\ngravity  %.2f m/s²\nlat %.4f°   lon %.4f°\n%s\n\nWASD move   Shift bound   Space jump   Esc free mouse" % [
		_h_speed, moon.gravity_vector.length(), lat, lon,
		"on ground" if is_on_floor() else "airborne"]
