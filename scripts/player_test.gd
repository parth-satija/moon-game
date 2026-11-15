extends MoonPlayer
## Test player with a stricter terrain guard (used by player_test.tscn, and applied to the game's player by the
## PlayerSwap autoload).
##
## Why the old player sank: the terrain collision is a thin trimesh that is swapped for a new one on a
## background thread, and the old guard tolerated 0.4 m / 0.12 m of embedding before lifting. Here:
##  - tolerances are tight (set in player_test.tscn), so you are never visibly inside the ground
##  - the exact-height floor runs BEFORE move_and_slide as well as after, so a freshly swapped mesh
##    that lands above the player is corrected before the physics step tries to resolve it
##  - a second ray starts well above the head, so terrain that swapped in over the whole capsule is found
##  - terminal fall speed is lower, so the thin mesh cannot be tunnelled through
##
## Also:
##  - auto_hop: while a movement key is held the player hops continuously, exactly as if Space were held
##    (a synthetic Space key press is fed to the same input check player.gd uses). Standing still: no hopping.
##  - spawn fix: until the first landing, the player is placed spawn_clearance_m above the exact ground if it
##    starts too high (the planet's spawn height ignores the crash-site crater) or inside the ground.

@export var auto_hop := true
@export var spawn_fix_frames := 600            # physics frames the spawn fix may run for (10 s at 60 Hz)
@export var spawn_clearance_m := 10.0          # the player is put this far above the ground, then drops

var _fake_space := false
var _spawn_landed := false
var _spawn_frames_left := 0


func _ready() -> void:
	super._ready()
	_spawn_frames_left = spawn_fix_frames


func _physics_process(delta: float) -> void:
	_fix_spawn_height()
	_update_auto_hop()
	_pre_guard()
	super._physics_process(delta)          # walking, move_and_slide(), and the base _guard_ground()
	_guard_ground()                         # second pass right after the move
	if is_on_floor():
		_spawn_landed = true


# ---------------------------------------------------------------- spawn
func _fix_spawn_height() -> void:
	if _spawn_landed or _spawn_frames_left <= 0 or moon == null or _driving():
		return
	_spawn_frames_left -= 1
	var h := moon.height_above_ground(self)
	# Too high, or at/below the surface (clipped): put it spawn_clearance_m above. A player that is merely
	# falling from that height is left alone, so it can land.
	if h > spawn_clearance_m + 1.0 or h < 0.0:
		moon.snap_to_ground(self, spawn_clearance_m)
		velocity = Vector3.ZERO


# ---------------------------------------------------------------- hopping
func _update_auto_hop() -> void:
	var moving := false
	if auto_hop and not _driving() and not Inventory.ui_open:
		moving = _down(KEY_W, KEY_UP) or _down(KEY_S, KEY_DOWN) or _down(KEY_A, KEY_LEFT) or _down(KEY_D, KEY_RIGHT)
	if moving == _fake_space:
		return
	_fake_space = moving
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_SPACE
	ev.keycode = KEY_SPACE
	ev.pressed = moving
	Input.parse_input_event(ev)             # player.gd reads Input.is_physical_key_pressed(KEY_SPACE)


func _exit_tree() -> void:
	if _fake_space:                         # never leave Space stuck down
		_fake_space = false
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_SPACE
		ev.keycode = KEY_SPACE
		ev.pressed = false
		Input.parse_input_event(ev)


# ---------------------------------------------------------------- terrain guard
func _pre_guard() -> void:
	if moon == null or not ground_guard:
		return
	var lifted := moon.ensure_above_ground(self, floor_margin_m, guard_clearance_m)
	if lifted > 0.0:
		_dip = minf(_dip + lifted, 0.5)


func _guard_ground() -> void:
	super._guard_ground()
	if moon == null or not ground_guard:
		return
	var up := up_direction
	var hit := _terrain_ray(up, guard_ray_height + 1.0, guard_probe_m)
	if hit.is_empty():
		return
	var surface: Vector3 = hit["position"]
	var depth := (surface - global_position).dot(up)
	if depth > guard_margin_m:
		global_position += up * (depth + guard_clearance_m)
		velocity -= up * minf(velocity.dot(up), 0.0)
		_dip = minf(_dip + depth, 0.5)
