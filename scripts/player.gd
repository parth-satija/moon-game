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

@export var max_fall_speed := 20.0       # m/s terminal speed, so a long fall cannot punch through the terrain

@export_group("Ground guard")
@export var ground_guard := true         # extra ray under the player that stops it sinking into the terrain
@export var guard_ray_height := 1.8      # the ray starts this far above the feet (the top of the capsule)
@export var guard_margin_m := 0.12       # feet may be this far under the surface before they are lifted
@export var guard_clearance_m := 0.05    # how far above the surface they are put
@export var guard_probe_m := 3.0         # how far below the feet the ray reaches
@export var floor_margin_m := 0.4        # feet may be this far under the exact ground height before they are lifted

@export_group("Camera")
@export var eye_height := 1.6
@export var fov := 78.0
@export var render_distance_m := 100000.0    # camera far plane: how far away objects (rovers, base, wreck) are still drawn
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
var _facing_model_name := "Nothing"

## The vehicle being driven (the lunar buggy, lrv.gd), or null on foot. While it is set, its drive_step() replaces
## the walking movement, the mouse turns the head instead of the body, F goes to its winch and E climbs out.
var vehicle: Node = null

const VEHICLE_LOOK_YAW := 1.9            # radians the head can turn to either side while driving


func _driving() -> bool:
	return vehicle != null and is_instance_valid(vehicle)


@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var model_raycast: RayCast3D = $Head/Camera3D/ModelRayCast


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	floor_max_angle = deg_to_rad(slope_limit_deg)
	floor_snap_length = 0.15          # small, so you can leave the ground over crests (low gravity)
	floor_stop_on_slope = true
	head.position.y = eye_height
	camera.fov = fov
	camera.far = render_distance_m
	camera.current = true
	model_raycast.add_exception(self)
	add_to_group("player")
	if moon == null and get_parent():
		moon = get_parent().get_node_or_null("MoonPlanet") as MoonPlanet
	_build_dust()
	_build_hud()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if Inventory.ui_open:
		return                         # the inventory window owns the mouse and keyboard
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _driving():
			head.rotation.y = clampf(head.rotation.y - event.relative.x * mouse_sensitivity, -VEHICLE_LOOK_YAW, VEHICLE_LOOK_YAW)
		else:
			rotate_object_local(Vector3.UP, -event.relative.x * mouse_sensitivity)
		var lim := deg_to_rad(max_pitch_deg)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -lim, lim)
		head.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		_interact_facing()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F and _driving():
		vehicle.call("use_lift")
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_teleport_to_next_objective()
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _teleport_to_next_objective() -> void:
	var target: Node3D
	var offset := 4.0
	if Repairs.stage_complete("rocket"):
		if Repairs.has_flag(Repairs.FLAG_WRECK_LIFTED):
			Dialogue.say("All objectives are complete.", 2.5)
			return
		target = LandingSite.wreck_anchor
		offset = 12.0
	else:
		target = get_tree().get_first_node_in_group("crafter") as Node3D      # the crafter is inside the base now

	if target == null or not is_instance_valid(target):
		Dialogue.say("The next objective location is not available.", 2.5)
		return

	var up := target.global_basis.y.normalized()
	var forward := -global_basis.z
	forward -= up * forward.dot(up)
	if forward.length_squared() < 1e-6:
		forward = -target.global_basis.z
	forward = forward.normalized()
	global_basis = Basis.looking_at(forward, up)
	up_direction = up
	var dest := target.global_position + target.global_basis.x.normalized() * offset
	global_position = dest + up * guard_clearance_m
	velocity = Vector3.ZERO
	_h_speed = 0.0
	_stand_at(dest, up)


# Puts the player on whatever it can stand on at dest: a floor right there (inside the base, once it has
# collision), otherwise the exact ground under it. That ground is measured as if the player were already there:
# measured from where the teleport started, the terrain detail is faded out and the player would arrive tens of
# metres too high or too low.
func _stand_at(dest: Vector3, up: Vector3) -> void:
	if moon == null:
		return
	var exclude: Array[RID] = [get_rid()]
	var query := PhysicsRayQueryParameters3D.create(dest + up * 1.5, dest - up * 3.0)
	query.exclude = exclude
	query.collide_with_areas = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		global_position = dest
		moon.snap_to_ground(self, guard_clearance_m)
	else:
		global_position = (hit["position"] as Vector3) + up * guard_clearance_m
		moon.ensure_above_ground(self, floor_margin_m, guard_clearance_m)


func _interact_facing() -> void:
	var target := _find_interactable()
	if target != null:
		target.call("interact", self)


# What E would act on: a WorldSite whose collider the view ray is touching, otherwise the nearest one the
# player is standing within the interact radius of.
func _find_interactable() -> Node:
	if _driving():
		return vehicle                  # E while driving always means "climb out"
	var collider := model_raycast.get_collider()
	if collider is Node:
		var candidate := collider as Node
		while candidate != null:
			if candidate.has_method("interact"):
				return candidate
			candidate = candidate.get_parent()
	var best: Node = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group("interactible"):
		if not (n is Node3D and n.has_method("interact")):
			continue
		var d := (n as Node3D).global_position.distance_to(global_position)
		if d <= float(n.get("interact_radius")) and d < best_d:
			best = n
			best_d = d
	return best


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
	if Inventory.ui_open:
		input = Vector2.ZERO
	var wish := right * input.x + fwd * input.y
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	var top := run_speed if Input.is_physical_key_pressed(KEY_SHIFT) else walk_speed
	if input.y < 0.0:
		top *= 0.6

	if _driving():
		vehicle.call("drive_step", self, delta, up, g, was_floor)
	elif was_floor:
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
		if Input.is_physical_key_pressed(KEY_SPACE) and not Inventory.ui_open:
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
	if fall_speed > max_fall_speed:
		velocity += up * (fall_speed - max_fall_speed)
		fall_speed = max_fall_speed
	move_and_slide()
	_guard_ground()

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


# ---------------------------------------------------------------- ground guard
# A second line of defence under the capsule. The terrain collision is a thin triangle mesh that is
# swapped for a new one every few metres, and on steep slopes the swap can leave the capsule below
# the new surface, from where nothing pushes it back out. So every physics frame a ray is fired
# DOWN the up axis through the capsule, from its top to a little below the feet, and checked against
# the terrain.
#
# The ray starts at the top of the capsule, not at the feet: a ray that starts below the surface
# points away from it and sees nothing. Starting inside the capsule, it hits the surface whenever the
# surface is anywhere between the head and the feet. On a slope the capsule rests with the terrain
# under its axis LOWER than its feet, so a hit above the feet only happens when the capsule is
# really embedded.
func _guard_ground() -> void:
	if not ground_guard or moon == null:
		return
	var up := up_direction
	# 1. The exact ground height, computed directly: needs no collision mesh, so it cannot go stale.
	var lifted := moon.ensure_above_ground(self, floor_margin_m, guard_clearance_m)
	if lifted > 0.0:
		_dip = minf(_dip + lifted, 0.5)
		print("Player: lifted %.2f m back onto the terrain (exact-height floor)" % lifted)
		return
	# 2. A ray through the capsule against the collision mesh, for shallower penetration.
	var hit := _terrain_ray(up, guard_ray_height, guard_probe_m)
	if hit.is_empty():
		return
	var surface: Vector3 = hit["position"]
	var depth := (surface - global_position).dot(up)        # > 0: the terrain is above the feet
	if depth <= guard_margin_m:
		return
	global_position += up * (depth + guard_clearance_m)
	velocity -= up * minf(velocity.dot(up), 0.0)            # cancel the downward speed, keep the rest
	_dip = minf(_dip + depth, 0.5)                          # ease the camera up instead of snapping it


# First terrain hit on a ray along the up axis, from 'above' metres over the feet to 'below' metres
# under them. Other bodies (rover, wreck) are looked through. Empty dictionary when nothing is hit.
func _terrain_ray(up: Vector3, above: float, below: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [get_rid()]
	var from := global_position + up * above
	var to := global_position - up * below
	for _i in 3:
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.exclude = exclude
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return hit
		var collider := hit["collider"] as Node
		if collider != null and collider.get_parent() == moon:
			return hit
		exclude.append(hit["rid"])
	return {}


func _stride_length() -> float:
	return lerpf(0.8, 2.4, clampf(_h_speed / maxf(run_speed, 0.1), 0.0, 1.0))


func _process(delta: float) -> void:
	_update_facing_model()
	# Slow, wide lunar bob: bigger and floatier the faster you go, gone in the air.
	var moving := is_on_floor() and _h_speed > 0.15 and not _driving()      # no walking bob in the buggy
	_bob_weight = lerpf(_bob_weight, 1.0 if moving else 0.0, 1.0 - exp(-8.0 * delta))
	if moving:
		_bob_phase = fposmod(_bob_phase + _h_speed / _stride_length() * TAU * delta, TAU * 2.0)
	var k := clampf(_h_speed / maxf(run_speed, 0.1), 0.0, 1.0)
	var amp := lerpf(0.012, 0.075, k) * bob_amount * _bob_weight
	_dip = lerpf(_dip, 0.0, 1.0 - exp(-2.5 * delta))
	head.position = Vector3(cos(_bob_phase * 0.5) * amp * 0.45, eye_height + sin(_bob_phase) * amp - _dip, 0.0)
	_update_hud()


func _update_facing_model() -> void:
	model_raycast.force_raycast_update()
	var collider := model_raycast.get_collider()
	var model_name := "Nothing"
	if collider is Node:
		var hit_node := collider as Node
		var model_root := hit_node.owner if hit_node.owner != null else hit_node
		model_name = str(model_root.name)
	_facing_model_name = model_name


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
	if _hud == null:
		return
	var inventory_text := "Objective: %s" % Repairs.objective_text()
	var target := _find_interactable()
	if target != null:
		inventory_text += "\nE: %s" % str(target.call("prompt_text"))
	if moon == null:
		_hud.text = "Facing: %s\n%s" % [_facing_model_name, inventory_text]
		return
	_hud.text = "speed    %.1f m/s\ngravity  %.2f m/s²\nmesh build %.1f s\n%s\n%s\nFacing: %s\n%s\n\nWASD move   Shift bound   Space jump   E interact   T objective teleport   I inventory / repairs   N nav slate   G sun/Earth sight   R range landmark   Esc pause" % [
		_h_speed, moon.gravity_vector.length(), moon._build_secs, LunarNav.hud_text(self),
		"on ground" if is_on_floor() else "airborne", _facing_model_name, inventory_text]
