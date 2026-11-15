extends WorldSite
## The lunar roving vehicle: "the buggy".
##
## E on it climbs into the driver's seat (once its power is back) and E again climbs out. While seated:
##     W / S  throttle / reverse        A / D  steer        Space  brake
##     F      winch lift (at the crash site)                 mouse  look around
##
## HOW IT DRIVES
##   The player body is the vehicle's physics body, so the planet's terrain streaming, floating origin and
##   ground guard keep working. While driving, the buggy is reparented under the player and player.gd hands
##   the walking movement over to drive_step() below. Lunar traction is poor: it accelerates slowly, slides
##   a little sideways and stays airborne over crests. Where it is left is saved with the slot
##   (GameState.record_object_pose), and so is being seated in it.
##
## HOW THE REPAIRS CHANGE IT   (the five repairs of the "buggy" stage in repairs.gd)
##   Buggy Electrical System   drive controller. Without it, or without the battery, the buggy is dead.
##   Buggy Battery System      the power. Without it the buggy is dead.
##   Wheel and Suspension      without it the wheels are seized and the buggy cannot move.
##   Steering System           without it the steering is locked straight and the boom hydraulics are offline.
##   Damaged Chassis           without it the frame rattles (low top speed) and cannot take the winch load.
##   The model shows every fault until it is repaired.
##
## WINCH LIFT
##   F at the crash site (within LIFT_RANGE_M of the hull, stopped, battery above LIFT_MIN_CHARGE, steering,
##   chassis and power repaired) lowers the outriggers, swings the boom round, runs the winch cable to a lug on
##   the hull and raises the crashed Starship LandingSite.LIFT_HEIGHT_M on stands. That opens its underside as a
##   new salvage site (Repairs.LOOT["wreck_underside"]). It happens once; it is saved as the "wreck_lifted" flag.
##
## BATTERY
##   Driving drains it, the winch takes a chunk, and it trickles back up from the solar skin while parked.
##
## The model is built from primitives in _build_model(). To use a real model, replace that function; the rig
## needs: _wheel_hubs / _wheel_spins (four, front pair first), _jacks, _boom_turret / _boom_arm / _boom_tip,
## _chassis, _battery_door and the three materials.

signal mounted
signal dismounted

enum Phase { NONE, DEPLOY, HOIST, STOW }

const SEAT_X := 0.45                  # the model is shifted so the driver's seat sits on this node's origin
const SEAT_EYE_M := 1.45
const WHEEL_RADIUS := 0.41

# --- driving
const TOP_SPEED := 8.5                # m/s
const DAMAGED_TOP_SPEED := 4.5        # m/s with the chassis unrepaired
const REVERSE_FACTOR := 0.45
const ACCEL := 2.0                    # m/s^2
const BRAKE_DECEL := 4.5
const COAST_DECEL := 0.5
const HANDBRAKE_DECEL := 7.0
const GRIP := 2.2                     # m/s^2 that pull sideways slip back to zero
const TURN_RATE := 0.85               # rad/s at full lock once rolling
const MAX_SLOPE_DEG := 30.0
const UPHILL_PENALTY := 0.6

# --- battery (0..1)
const DRAIN_PER_S := 0.0012           # at full throttle: about 14 minutes of flat-out driving
const RECHARGE_PARKED_PER_S := 0.005
const RECHARGE_SEATED_PER_S := 0.0015

# --- winch lift
const LIFT_RANGE_M := 14.0            # from the buggy to the hull's surface
const LIFT_MIN_CHARGE := 0.4
const LIFT_COST := 0.3
const DEPLOY_SECONDS := 2.5
const HOIST_SECONDS := 9.0
const STOW_SECONDS := 2.0

const BOOM_LENGTH := 1.7
const BOOM_STOW_YAW := PI             # stowed: pointing out over the back
const BOOM_STOW_PITCH := 0.09
const JACK_STOWED_SCALE := 0.15

const FRAME_OK := Color(0.72, 0.73, 0.76)
const FRAME_DAMAGED := Color(0.38, 0.35, 0.33)

## Battery charge, 0..1.
var charge := 1.0

var _driver: MoonPlayer = null
var _home: Node = null
var _saved_eye := 1.6
var _saved_floor_angle := 0.66
var _saved_snap := 0.15
var _tilt := Quaternion.IDENTITY
var _v_f := 0.0                       # speed along the heading (m/s, negative in reverse)
var _speed := 0.0
var _wheel_angle := 0.0
var _steer_visual := 0.0
var _steer_ok := false
var _warn_cd := 0.0

var _model: Node3D
var _body: StaticBody3D
var _chassis: Node3D
var _frame_mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _screen_mat: StandardMaterial3D
var _battery_door: Node3D
var _wheel_hubs: Array[Node3D] = []
var _wheel_spins: Array[Node3D] = []
var _jacks: Array[Node3D] = []
var _boom_turret: Node3D
var _boom_arm: Node3D
var _boom_tip: Node3D
var _cable: MeshInstance3D
var _fuel_tank: MeshInstance3D

var _phase := Phase.NONE
var _phase_t := 0.0
var _lug: Node3D
var _boom_yaw_to := PI
var _boom_pitch_to := 0.3
var _charge_at_start := 1.0

var _hud_layer: CanvasLayer
var _hud: Label


func _init() -> void:
	label = "lunar buggy"
	interact_radius = 5.0


func _ready() -> void:
	super._ready()                                # joins the "interactible" group
	add_to_group("lrv")                          # Life finds the buggy by this group (it moves under the player while driven)
	_build_model()
	_build_body()
	_build_cable()
	_apply_rig(0.0, 0.0)
	_refresh_visuals()
	Repairs.changed.connect(_refresh_visuals)


func _exit_tree() -> void:
	if _driver != null and is_instance_valid(_driver) and _driver.vehicle == self:
		_driver.vehicle = null


# ================================================================= interaction

func prompt_text() -> String:
	if _driver != null:
		return "Climb out of the buggy"
	if _phase != Phase.NONE:
		return "Buggy: winch working"
	if not _has_power():
		return "Inspect the buggy"
	return "Drive the buggy"


func interact(p: Node) -> void:
	if _driver != null:
		dismount()
	elif p is MoonPlayer:
		_try_mount(p as MoonPlayer)


func _has_power() -> bool:
	return Repairs.is_done("buggy_electrical") and Repairs.is_done("buggy_battery")


func _try_mount(p: MoonPlayer) -> void:
	if _phase != Phase.NONE:
		return
	if not _has_power():
		var missing: Array[String] = []
		for id in ["buggy_electrical", "buggy_battery"]:
			if not Repairs.is_done(id):
				missing.append(Repairs.repair_name(id))
		var text := "The buggy is dead."
		if Repairs.stage_unlocked("buggy"):
			text += " Repair at the crafter: %s." % ", ".join(missing)
		else:
			text += " Finish the solar panel repairs first, then restore its power at the crafter."
		Dialogue.say(text, 5.0)
		return
	_mount(p)


## Seats the player without any checks (GameState uses it to resume a saved drive).
func mount_player(p: Node) -> void:
	if p is MoonPlayer and _driver == null:
		_mount(p as MoonPlayer)


func _mount(p: MoonPlayer) -> void:
	_driver = p
	_home = get_parent()
	var up := p.up_direction
	var y_before := global_basis.y.normalized()
	var fwd := -global_basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-6:
		fwd = -p.global_basis.z
		fwd -= up * fwd.dot(up)
	fwd = fwd.normalized()

	# The player sits on the buggy's origin (the driver's seat), facing along it.
	p.global_position = global_position + up * 0.1
	p.velocity = Vector3.ZERO
	p.global_basis = Basis.looking_at(fwd, up)
	p.head.rotation.y = 0.0
	_saved_eye = p.eye_height
	_saved_floor_angle = p.floor_max_angle
	_saved_snap = p.floor_snap_length
	p.eye_height = SEAT_EYE_M
	p.floor_max_angle = deg_to_rad(MAX_SLOPE_DEG)
	p.floor_snap_length = 0.5

	# Ride on the player: out of the rebase group (the player is the thing that stays at the origin).
	var group := _rebase_group()
	if is_in_group(group):
		remove_from_group(group)
	_body.collision_layer = 0
	reparent(p, true)
	var n_local := (p.global_basis.inverse() * y_before).normalized()
	_tilt = Quaternion(Vector3.UP, n_local)
	transform = Transform3D(Basis(_tilt), Vector3.ZERO)

	p.vehicle = self
	_v_f = 0.0
	_build_hud()
	mounted.emit()


func dismount() -> void:
	if _driver == null or _phase != Phase.NONE:
		return
	var p := _driver
	var home := _home if (_home != null and is_instance_valid(_home)) else MoonPlanet.instance
	reparent(home, true)
	add_to_group(_rebase_group())
	_body.collision_layer = 1

	p.vehicle = null
	p.eye_height = _saved_eye
	p.floor_max_angle = _saved_floor_angle
	p.floor_snap_length = _saved_snap
	p.head.rotation.y = 0.0
	p.velocity = Vector3.ZERO
	# Step out on the driver's side.
	p.global_position += (-global_basis.x).normalized() * 1.7 + p.up_direction * 0.1

	_driver = null
	_v_f = 0.0
	_speed = 0.0
	_free_hud()
	GameState.record_object_pose(self)
	dismounted.emit()


func _rebase_group() -> String:
	return MoonPlanet.instance.rebase_group if MoonPlanet.instance != null else "rebase"


# ================================================================= driving

static func _key(a: Key, b: Key = KEY_NONE) -> bool:
	return Input.is_physical_key_pressed(a) or (b != KEY_NONE and Input.is_physical_key_pressed(b))


func _axis(pos_a: Key, pos_b: Key, neg_a: Key, neg_b: Key) -> float:
	return float(_key(pos_a, pos_b)) - float(_key(neg_a, neg_b))


# Why the buggy cannot move right now ("" when it can).
func _blocked_reason() -> String:
	if not Repairs.is_done("buggy_wheels"):
		return "The wheels are seized. Repair the wheel and suspension system at the crafter."
	if charge <= 0.0:
		return "The battery is flat. Wait a few minutes for the solar skin to recharge it."
	return ""


## Called by player.gd every physics frame while it is driving, in place of the walking movement. Sets the
## player's velocity and heading; the player then moves with move_and_slide() as usual.
func drive_step(p: MoonPlayer, delta: float, up: Vector3, g: Vector3, was_floor: bool) -> void:
	var busy := _phase != Phase.NONE or Inventory.ui_open
	var throttle := 0.0
	var steer := 0.0
	var handbrake := false
	if not busy:
		throttle = _axis(KEY_W, KEY_UP, KEY_S, KEY_DOWN)
		steer = _axis(KEY_D, KEY_RIGHT, KEY_A, KEY_LEFT)
		handbrake = Input.is_physical_key_pressed(KEY_SPACE)
	if _phase != Phase.NONE:
		handbrake = true                             # the outriggers are down: the buggy stays put

	var why := _blocked_reason()
	var can_roll := why == ""
	if throttle != 0.0 and not can_roll and _warn_cd <= 0.0:
		_warn_cd = 8.0
		Dialogue.say(why, 4.0)

	var fwd := -p.global_basis.z
	fwd -= up * fwd.dot(up)
	if fwd.length_squared() < 1e-8:
		fwd = up.cross(p.global_basis.x)
	fwd = fwd.normalized()
	var right := fwd.cross(up).normalized()
	var v_h := p.velocity - up * p.velocity.dot(up)
	var v_f := v_h.dot(fwd)
	var v_l := v_h.dot(right)

	if was_floor:
		var top := TOP_SPEED if Repairs.is_done("buggy_chassis") else DAMAGED_TOP_SPEED
		var n := p.get_floor_normal()
		var slope := acos(clampf(n.dot(up), -1.0, 1.0))
		var downhill := n * n.dot(up) - up
		if downhill.length_squared() > 1e-6 and absf(v_f) > 0.05:
			var uphill := clampf(-(fwd * signf(v_f)).dot(downhill.normalized()), 0.0, 1.0)
			top *= 1.0 - UPHILL_PENALTY * uphill * clampf(slope / maxf(p.floor_max_angle, 0.01), 0.0, 1.0)

		var target := 0.0
		if can_roll:
			target = throttle * (top if throttle > 0.0 else top * REVERSE_FACTOR)
		var rate := COAST_DECEL
		if throttle != 0.0 and can_roll:
			if target * v_f < -0.01:
				rate = BRAKE_DECEL                    # throttle against the direction of travel
			elif absf(target) > absf(v_f):
				rate = ACCEL
			else:
				rate = COAST_DECEL * 3.0              # over the limit (uphill): bleed the speed off
		if handbrake:
			target = 0.0
			rate = HANDBRAKE_DECEL
		v_f = move_toward(v_f, target, rate * delta)
		v_l = move_toward(v_l, 0.0, GRIP * delta)
		p.velocity = fwd * v_f + right * v_l + g * delta   # the small pull keeps the floor contact stable

		if _steer_ok and absf(v_f) > 0.05:
			var turn := clampf(absf(v_f) / 2.5, 0.0, 1.0)
			p.rotate_object_local(Vector3.UP, -steer * TURN_RATE * turn * signf(v_f) * delta)
		if can_roll:
			charge = maxf(0.0, charge - DRAIN_PER_S * absf(throttle) * delta)
	else:
		p.velocity += g * delta                       # airborne: ballistic, no control

	_steer_visual = lerpf(_steer_visual, -steer * 0.45, 1.0 - exp(-8.0 * delta))
	_v_f = v_f
	_speed = v_h.length()


# ================================================================= per frame

func _process(delta: float) -> void:
	_warn_cd = maxf(0.0, _warn_cd - delta)
	if _phase != Phase.NONE:
		_update_lift(delta)
	if _driver != null:
		_update_seated(delta)
		if absf(_v_f) < 0.2 and _phase == Phase.NONE:
			charge = minf(1.0, charge + RECHARGE_SEATED_PER_S * delta)
	else:
		charge = minf(1.0, charge + RECHARGE_PARKED_PER_S * delta)
	_update_wheels(delta)
	_update_cable()
	if _fuel_tank != null:
		_fuel_tank.visible = Life.buggy_cargo >= 1.0


func _update_seated(delta: float) -> void:
	var p := _driver
	if p.is_on_floor():
		var n_local := (p.global_basis.inverse() * p.get_floor_normal()).normalized()
		_tilt = _tilt.slerp(Quaternion(Vector3.UP, n_local), 1.0 - exp(-5.0 * delta))
	transform = Transform3D(Basis(_tilt), Vector3.ZERO)
	if _hud != null:
		_hud.text = _hud_text()


func _update_wheels(delta: float) -> void:
	_wheel_angle -= _v_f / WHEEL_RADIUS * delta       # rolling forward (-Z) turns the wheel about -X
	for i in _wheel_hubs.size():
		_wheel_spins[i].rotation.x = _wheel_angle
		if i < 2:                                     # the front pair steers; unrepaired steering leaves them toed out
			var toe := deg_to_rad(22.0) * (1.0 if i == 0 else -1.0)
			_wheel_hubs[i].rotation.y = _steer_visual if _steer_ok else toe


## Re-reads the repairs and shows them on the model.
func _refresh_visuals() -> void:
	if _model == null:
		return
	var chassis_ok := Repairs.is_done("buggy_chassis")
	_chassis.rotation.z = 0.0 if chassis_ok else deg_to_rad(-3.5)
	_chassis.position.y = 0.0 if chassis_ok else -0.04
	_frame_mat.albedo_color = FRAME_OK if chassis_ok else FRAME_DAMAGED

	var wheels_ok := Repairs.is_done("buggy_wheels")
	for i in _wheel_hubs.size():
		_wheel_hubs[i].visible = wheels_ok or i != 0              # the front-left wheel is missing
		_wheel_hubs[i].rotation.z = 0.0 if wheels_ok else deg_to_rad(12.0 if i % 2 == 0 else -12.0)   # bent hubs

	_steer_ok = Repairs.is_done("buggy_steering")
	_lamp_mat.emission_enabled = _has_power()
	_screen_mat.emission_enabled = Repairs.is_done("buggy_electrical")
	_battery_door.rotation.y = 0.0 if Repairs.is_done("buggy_battery") else deg_to_rad(-80.0)


# ================================================================= winch lift

## "" when the winch can lift the Starship right now, otherwise what is missing.
func lift_block_reason() -> String:
	if Repairs.has_flag(Repairs.FLAG_WRECK_LIFTED):
		return "The Starship is already raised."
	if not LandingSite.has_wreck():
		return "There is nothing here to lift."
	if not _has_power():
		return "The buggy has no power."
	if not Repairs.is_done("buggy_steering"):
		return "The boom hydraulics are offline. Repair the steering system at the crafter."
	if not Repairs.is_done("buggy_chassis"):
		return "The frame cannot take the winch load. Repair the chassis at the crafter."
	var d := LandingSite.distance_to_wreck(global_position)
	if d > LIFT_RANGE_M:
		return "Drive closer to the Starship: it is %d m away and the winch reaches %d m." % [int(d), int(LIFT_RANGE_M)]
	if charge < LIFT_MIN_CHARGE:
		return "The battery is too low for the winch (%d%%, it needs %d%%)." % [int(charge * 100.0), int(LIFT_MIN_CHARGE * 100.0)]
	if _driver != null and _driver.get_real_velocity().length() > 0.6:
		return "Stop the buggy first."
	return ""


## F while driving (called by player.gd).
func use_lift() -> void:
	if _driver == null or _phase != Phase.NONE:
		return
	var why := lift_block_reason()
	if why != "":
		Dialogue.say(why, 4.0)
		return
	_start_lift()


func _start_lift() -> void:
	_lug = LandingSite.begin_wreck_lift(global_position)
	if _lug == null:
		return
	# Aim the boom at the lug, in the frame the turret sits in.
	var d := _model.to_local(_lug.global_position) - _boom_turret.position
	_boom_yaw_to = atan2(-d.x, -d.z)
	_boom_pitch_to = clampf(atan2(d.y, maxf(Vector2(d.x, d.z).length(), 0.1)), deg_to_rad(12.0), deg_to_rad(60.0))
	_charge_at_start = charge
	_phase = Phase.DEPLOY
	_phase_t = 0.0
	Dialogue.say("Outriggers down. Hooking up the winch.", 3.0, "Buggy")


func _update_lift(delta: float) -> void:
	_phase_t += delta
	match _phase:
		Phase.DEPLOY:
			var k := smoothstep(0.0, 1.0, _phase_t / DEPLOY_SECONDS)
			_apply_rig(k, k)
			if _phase_t >= DEPLOY_SECONDS:
				_phase = Phase.HOIST
				_phase_t = 0.0
				Dialogue.say("Winch engaged. Lifting the Starship.", 3.0, "Buggy")
		Phase.HOIST:
			var raw := clampf(_phase_t / HOIST_SECONDS, 0.0, 1.0)
			LandingSite.set_wreck_lift(smoothstep(0.0, 1.0, raw))
			charge = maxf(0.0, _charge_at_start - LIFT_COST * raw)
			_shake_camera(0.012)
			if raw >= 1.0:
				LandingSite.finish_wreck_lift()
				_shake_camera(0.0)
				_phase = Phase.STOW
				_phase_t = 0.0
		Phase.STOW:
			var k := 1.0 - smoothstep(0.0, 1.0, _phase_t / STOW_SECONDS)
			_apply_rig(k, k)
			if _phase_t >= STOW_SECONDS:
				_phase = Phase.NONE
				_lug = null
				Dialogue.say("The Starship is raised and propped on its stands. Its underside is open: salvage it.", 6.0)


func _shake_camera(amount: float) -> void:
	if _driver == null:
		return
	_driver.camera.h_offset = randf_range(-amount, amount)
	_driver.camera.v_offset = randf_range(-amount, amount)


# jack_k / boom_k: 0 = stowed, 1 = deployed.
func _apply_rig(jack_k: float, boom_k: float) -> void:
	for leg in _jacks:
		leg.scale.y = lerpf(JACK_STOWED_SCALE, 1.0, jack_k)
	_boom_turret.rotation.y = lerp_angle(BOOM_STOW_YAW, _boom_yaw_to, boom_k)
	_boom_arm.rotation.x = lerpf(BOOM_STOW_PITCH, _boom_pitch_to, boom_k)


# The winch cable: a thin cylinder stretched from the boom tip to the lug on the hull.
func _update_cable() -> void:
	if _cable == null:
		return
	var show := _lug != null and is_instance_valid(_lug) and (_phase == Phase.HOIST or (_phase == Phase.DEPLOY and _phase_t > DEPLOY_SECONDS * 0.6))
	_cable.visible = show
	if not show:
		return
	var a := _boom_tip.global_position
	var b := _lug.global_position
	var d := b - a
	var length := d.length()
	if length < 0.05:
		return
	var y := d / length
	var x := (Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).cross(y).normalized()
	var z := x.cross(y).normalized()
	_cable.global_transform = Transform3D(Basis(x, y * length, z), (a + b) * 0.5)


# ================================================================= HUD

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 6
	_hud = Label.new()
	_hud.anchor_left = 1.0
	_hud.anchor_right = 1.0
	_hud.anchor_top = 0.0
	_hud.anchor_bottom = 0.0
	_hud.offset_left = -700.0
	_hud.offset_right = -18.0
	_hud.offset_top = 14.0
	_hud.offset_bottom = 170.0
	_hud.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_hud.add_theme_constant_override("shadow_offset_x", 1)
	_hud.add_theme_constant_override("shadow_offset_y", 1)
	_hud_layer.add_child(_hud)
	add_child(_hud_layer)
	_hud.text = _hud_text()


func _free_hud() -> void:
	if _hud_layer != null:
		_hud_layer.queue_free()
	_hud_layer = null
	_hud = null


func _ok(repair_id: String) -> String:
	return "ok" if Repairs.is_done(repair_id) else "FAULT"


func _hud_text() -> String:
	var filled := int(round(clampf(charge, 0.0, 1.0) * 12.0))
	var lines: Array[String] = []
	lines.append("BUGGY   %.1f m/s   (%d km/h)" % [_speed, int(round(_speed * 3.6))])
	lines.append("battery [%s%s] %d%%" % ["#".repeat(filled), "-".repeat(12 - filled), int(round(charge * 100.0))])
	lines.append("controller %s   battery %s   wheels %s   steering %s   frame %s" % [
		_ok("buggy_electrical"), _ok("buggy_battery"), _ok("buggy_wheels"), _ok("buggy_steering"), _ok("buggy_chassis")])
	var status := _lift_status()
	if status != "":
		lines.append(status)
	lines.append("W/S drive   A/D steer   Space brake   F winch lift   E climb out")
	return "\n".join(lines)


func _lift_status() -> String:
	match _phase:
		Phase.DEPLOY:
			return "Winch: setting up..."
		Phase.HOIST:
			return "Winch: lifting the Starship  %d%%" % int(clampf(_phase_t / HOIST_SECONDS, 0.0, 1.0) * 100.0)
		Phase.STOW:
			return "Winch: stowing..."
	if LandingSite.distance_to_wreck(global_position) > 45.0:
		return ""
	var why := lift_block_reason()
	return "F: lift the Starship" if why == "" else why


# ================================================================= model

func _mat(color: Color, metallic := 0.0, rough := 0.8) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = rough
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, radius: float, height: float, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	cm.radial_segments = 14
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


# Forward is -Z, up is +Y, the origin is on the ground under the driver's seat. Dimensions follow the Apollo LRV
# (about 3 m long, 2 m wide, wheels 0.82 m across).
func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	_model.position = Vector3(SEAT_X, 0.0, 0.0)
	add_child(_model)

	_frame_mat = _mat(FRAME_OK, 0.6, 0.45)
	var foil := _mat(Color(0.86, 0.66, 0.22), 0.8, 0.35)
	var dark := _mat(Color(0.16, 0.16, 0.18), 0.3, 0.8)
	var steel := _mat(Color(0.55, 0.56, 0.58), 0.7, 0.5)
	var fabric := _mat(Color(0.8, 0.77, 0.68), 0.0, 0.95)
	var white := _mat(Color(0.9, 0.9, 0.92), 0.2, 0.5)
	var orange := _mat(Color(0.95, 0.5, 0.1), 0.3, 0.6)
	_lamp_mat = _mat(Color(0.4, 0.38, 0.3), 0.0, 0.4)
	_lamp_mat.emission = Color(1.0, 0.95, 0.8)
	_lamp_mat.emission_energy_multiplier = 2.5
	_screen_mat = _mat(Color(0.05, 0.12, 0.06), 0.0, 0.3)
	_screen_mat.emission = Color(0.3, 1.0, 0.45)
	_screen_mat.emission_energy_multiplier = 1.5

	# Frame, seats, electronics: everything in _chassis sags when the chassis is unrepaired.
	_chassis = Node3D.new()
	_chassis.name = "Chassis"
	_model.add_child(_chassis)
	_box(_chassis, Vector3(1.5, 0.08, 2.5), Vector3(0.0, 0.62, 0.0), _frame_mat)             # floor
	_box(_chassis, Vector3(0.07, 0.1, 2.9), Vector3(-0.76, 0.66, 0.0), _frame_mat)           # side rails
	_box(_chassis, Vector3(0.07, 0.1, 2.9), Vector3(0.76, 0.66, 0.0), _frame_mat)
	_box(_chassis, Vector3(1.6, 0.08, 0.08), Vector3(0.0, 0.66, -1.45), _frame_mat)          # cross members
	_box(_chassis, Vector3(1.6, 0.08, 0.08), Vector3(0.0, 0.66, 1.45), _frame_mat)
	_box(_chassis, Vector3(1.3, 0.3, 0.55), Vector3(0.0, 0.83, -1.0), foil)                  # front electronics bay
	_box(_chassis, Vector3(0.45, 0.25, 0.4), Vector3(0.5, 0.85, 1.15), white)                # tool box
	var tank_mat := _mat(Color(1.0, 0.62, 0.2), 0.4, 0.5)
	_fuel_tank = _cyl(_chassis, 0.17, 0.55, Vector3(0.62, 1.0, 0.75), tank_mat)   # shown while the buggy carries fuel
	_fuel_tank.visible = false
	for sx in [-0.45, 0.45]:
		_box(_chassis, Vector3(0.5, 0.07, 0.45), Vector3(sx, 0.76, 0.1), fabric)             # seat
		_box(_chassis, Vector3(0.5, 0.5, 0.06), Vector3(sx, 1.02, 0.34), fabric)             # seat back
		_box(_chassis, Vector3(0.4, 0.04, 0.2), Vector3(sx, 0.68, -0.35), dark)              # footrest
	_cyl(_chassis, 0.025, 0.5, Vector3(0.0, 0.88, -0.5), steel)                              # control post
	_box(_chassis, Vector3(0.4, 0.04, 0.04), Vector3(0.0, 1.13, -0.5), dark)                 # hand controller
	var screen := _box(_chassis, Vector3(0.2, 0.12, 0.02), Vector3(-0.45, 1.08, -0.6), _screen_mat)
	screen.rotation.x = deg_to_rad(-25.0)
	_box(_chassis, Vector3(0.7, 0.36, 0.5), Vector3(-0.45, 0.88, 1.2), dark)                 # battery box
	_battery_door = Node3D.new()
	_battery_door.position = Vector3(-0.8, 0.88, 1.45)                                       # hinge on its left edge
	_chassis.add_child(_battery_door)
	_box(_battery_door, Vector3(0.7, 0.34, 0.03), Vector3(0.35, 0.0, 0.0), foil)
	_cyl(_chassis, 0.02, 0.9, Vector3(0.82, 1.1, -0.95), steel)                              # antenna mast
	var dish := MeshInstance3D.new()
	var dm := CylinderMesh.new()
	dm.top_radius = 0.32
	dm.bottom_radius = 0.03
	dm.height = 0.12
	dish.mesh = dm
	dish.material_override = white
	dish.position = Vector3(0.82, 1.58, -0.95)
	dish.rotation.x = deg_to_rad(35.0)
	_chassis.add_child(dish)
	for lx in [-0.55, 0.55]:
		var lamp := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.07
		sm.height = 0.14
		lamp.mesh = sm
		lamp.material_override = _lamp_mat
		lamp.position = Vector3(lx, 0.85, -1.3)
		_chassis.add_child(lamp)

	# Wheels: front pair first (the steering pair). A hub steers, its spin node rolls.
	var corners: Array[Vector2] = [Vector2(-0.95, -1.15), Vector2(0.95, -1.15), Vector2(-0.95, 1.15), Vector2(0.95, 1.15)]
	for c: Vector2 in corners:
		var hub := Node3D.new()
		hub.position = Vector3(c.x, WHEEL_RADIUS, c.y)
		_model.add_child(hub)
		var spin := Node3D.new()
		hub.add_child(spin)
		_cyl(spin, WHEEL_RADIUS, 0.23, Vector3.ZERO, dark, Vector3(0.0, 0.0, PI * 0.5))
		for i in 3:
			var spoke := _box(spin, Vector3(0.26, 0.05, WHEEL_RADIUS * 2.0 - 0.06), Vector3.ZERO, steel)
			spoke.rotation.x = i * PI / 3.0
		_wheel_hubs.append(hub)
		_wheel_spins.append(spin)
		_box(_chassis, Vector3(0.3, 0.03, 0.85), Vector3(c.x, 0.92, c.y), white)             # fender

	# Outriggers: four legs that hang from the frame and are squashed up while stowed.
	for jc: Vector2 in [Vector2(-0.8, -1.55), Vector2(0.8, -1.55), Vector2(-0.8, 1.55), Vector2(0.8, 1.55)]:
		var leg := Node3D.new()
		leg.position = Vector3(jc.x, 0.62, jc.y)
		_model.add_child(leg)
		_cyl(leg, 0.05, 0.6, Vector3(0.0, -0.3, 0.0), dark)
		_cyl(leg, 0.14, 0.04, Vector3(0.0, -0.6, 0.0), orange)
		_jacks.append(leg)

	# Boom on a turret over the rear bed. rotation.y swings it, rotation.x raises it; it points along -Z.
	_boom_turret = Node3D.new()
	_boom_turret.position = Vector3(0.0, 0.7, 1.15)
	_model.add_child(_boom_turret)
	_cyl(_boom_turret, 0.15, 0.12, Vector3(0.0, 0.03, 0.0), dark)
	_boom_arm = Node3D.new()
	_boom_arm.position = Vector3(0.0, 0.12, 0.0)
	_boom_turret.add_child(_boom_arm)
	_box(_boom_arm, Vector3(0.09, 0.09, BOOM_LENGTH), Vector3(0.0, 0.0, -BOOM_LENGTH * 0.5), orange)
	_boom_tip = Node3D.new()
	_boom_tip.position = Vector3(0.0, 0.0, -BOOM_LENGTH)
	_boom_arm.add_child(_boom_tip)
	_box(_boom_tip, Vector3(0.1, 0.1, 0.1), Vector3.ZERO, white)


# A solid box so the buggy can be pointed at and walked around when parked. It is switched off while driving.
func _build_body() -> void:
	_body = StaticBody3D.new()
	_body.name = "Body"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.4, 1.3, 3.3)
	shape.shape = box
	shape.position = Vector3(0.0, 0.75, 0.0)
	_body.add_child(shape)
	_model.add_child(_body)


func _build_cable() -> void:
	_cable = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.03
	cm.height = 1.0
	cm.radial_segments = 6
	cm.rings = 1
	_cable.mesh = cm
	_cable.material_override = _mat(Color(0.1, 0.1, 0.11), 0.6, 0.5)
	_cable.top_level = true
	_cable.visible = false
	_cable.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cable)
