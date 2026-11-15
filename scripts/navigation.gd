extends Node
## Autoload "LunarNav": navigation is the main challenge.
##
## Mission control cannot track the player. It only knows the crash site, the base and the drop points
## (published as lat / lon, with scatter: a rover can lie some hundred metres from its drop point). The player has
## no GPS. Position is dead-reckoned by the nav computer from a pedometer / wheel odometer and a gyro heading,
## all with hidden errors, and corrected with:
##     touch fix      (NavSlate button)  at the crash hull or the base
##     sun/Earth sight (G)               centre the Sun or Earth in the crosshair: re-aligns the gyro
##     laser range    (R)                aim at the crash site or base: range + gyro bearing -> position fix
## The nav computer states its own uncertainty (1 sigma), computed from its error model, not from the truth.
##
## Everything hidden (gyro error, biases) is saved in the slot, so reloading does not reset the errors.
## Hooks used by GameState: begin_session(save, moon), get_state(), end_session().
## Debug builds: F3 shows the true position and the real DR error on the HUD.

signal event_logged(text: String)
signal mc_changed

const DEG := 57.29577951308232
const FALLBACK_RADIUS_M := 1737400.0

# ---- tunables ---------------------------------------------------------------------------------
const GYRO_BIAS_MIN_DEG_MIN := 0.04          # hidden gyro drift per slot, deg per minute (random sign)
const GYRO_BIAS_MAX_DEG_MIN := 0.12
const GYRO_RANDOM_WALK := 0.012              # deg / sqrt(second)
const GYRO_START_ERR_DEG := 1.5              # misalignment after the crash
const FOOT_BIAS_MAX := 0.025                 # hidden pedometer scale error
const WHEEL_BIAS_MAX := 0.02                 # hidden wheel odometer scale error
const WHEEL_SLIP_BASE := 0.010               # wheels over-read: slip on regolith
const WHEEL_SLIP_PER_RAD := 0.25             # extra slip per radian of slope
const ODO_SIGMA_FRAC := 0.04                 # what the computer assumes about odometer error
const COMPUTER_DRIFT_DEG_MIN := 0.12         # worst-case drift the computer assumes
const SIGHT_CONE_DEG := 6.0
const SIGHT_COOLDOWN_S := 3.0
const MAX_SIGHT_ELEV_DEG := 78.0
const RANGE_CONE_DEG := 5.0
const RANGE_COOLDOWN_S := 2.0
const START_FIX_SIGMA_M := 45.0
const LOST_FIX_SIGMA_M := 150.0
const ARRIVE_ROVER_M := 20.0                 # this close to a rover wreck counts as having found it
const ARRIVE_ROCKET_M := 45.0                # ... and this close to the return spacecraft
const FLAG_ROVER_FOUND := "rover_found"      # one-off events, saved in the slot through Repairs' flags
const FLAG_ROCKET_FOUND := "rocket_found"

## Landmarks that can be touched or ranged. height: for the horizon test. extent: size of the object (position error).
const LANDMARKS := {
	"crash": {"label": "crash site", "height_m": 45.0, "touch_m": 15.0, "touch_sigma_m": 20.0, "extent_m": 15.0, "mc_sigma_m": 6.0},
	"base": {"label": "lunar base", "height_m": 10.0, "touch_m": 30.0, "touch_sigma_m": 12.0, "extent_m": 6.0, "mc_sigma_m": 4.0},
}

## Mission control's sheet. kind "landmark": published = true position + small error. kind "drop": published =
## true position + scatter of min..max metres in a random direction. unlock: repair stage that must be complete.
const POINTS := [
	{"id": "crash", "name": "Crash site (Starship)", "kind": "landmark", "node": "", "unlock": "", "sigma": 6.0},
	{"id": "base", "name": "Lunar base", "kind": "landmark", "node": "InteriorBase", "unlock": "", "sigma": 4.0},
	{"id": "drop_a", "name": "Drop point A (rover)", "kind": "drop", "node": "Rover1_1", "unlock": "", "min": 70.0, "max": 220.0},
	{"id": "drop_b", "name": "Drop point B (rover)", "kind": "drop", "node": "Rover1_2", "unlock": "", "min": 70.0, "max": 220.0},
	{"id": "drop_c", "name": "Drop point C (rover)", "kind": "drop", "node": "Rover1_3", "unlock": "", "min": 70.0, "max": 220.0},
	{"id": "drop_solar", "name": "Drop point D (solar array)", "kind": "drop", "node": "SolarArray", "unlock": "base", "min": 40.0, "max": 150.0},
	{"id": "drop_lrv", "name": "Drop point E (lunar buggy)", "kind": "drop", "node": "LRV", "unlock": "solar", "min": 40.0, "max": 150.0},
	{"id": "drop_rocket", "name": "Landing point (return spacecraft)", "kind": "drop", "node": "ReturnRocket", "unlock": "buggy", "min": 30.0, "max": 100.0},
]

var active := false
var debug_truth := false

var _moon: MoonPlanet
var _env: LunarEnvironment
var _save_seed := 1
var _t_play := 0.0
var _have_prev := false
var _prev := PackedFloat64Array([0.0, 0.0, 0.0])

# estimate (radians) and its bookkeeping
var _est_lat := 0.0
var _est_lon := 0.0
var _fix_sigma_m := LOST_FIX_SIGMA_M
var _since_fix_m := 0.0
var _trip_e := 0.0
var _trip_n := 0.0
var _odo_total_m := 0.0
var _t_fix := 0.0
var _fix_label := ""

# gyro
var _gyro_err_deg := 0.0                      # hidden truth
var _gyro_bias_dps := 0.0                     # hidden truth
var _gyro_corr_deg := 0.0                     # applied by sights (known to the computer)
var _hdg_sigma0_deg := 2.0
var _t_sight := 0.0
var _sight_cd := 0.0
var _range_cd := 0.0

# odometers (hidden truth)
var _foot_bias := 0.0
var _wheel_bias := 0.0

var _mc := {}                                 # id -> {"lon_deg", "lat_deg"}
var _uplinked := {}                           # id -> true
var _briefed := false
var _arrive_cd := 0.0


func _ready() -> void:
	Repairs.stage_completed.connect(_on_stage_completed)


# ================================================================= session

func begin_session(save: Dictionary, moon: MoonPlanet) -> void:
	_moon = moon
	_env = null
	_save_seed = int(save.get("seed", 1))
	_have_prev = false
	_sight_cd = 0.0
	_range_cd = 0.0
	_mc = {}
	_uplinked = {}
	var state: Dictionary = save.get("nav", {})
	var fresh := state.is_empty()
	var rng := RandomNumberGenerator.new()
	rng.seed = _save_seed + 104729
	if fresh:
		_init_errors(rng)
	else:
		_load_state(state)
	active = true
	_build_mc()
	_watch_base_airlock()
	if fresh:
		_init_position(rng)
	_refresh_unlocks(false)
	if not _briefed:
		_brief()


func end_session() -> void:
	active = false
	_moon = null
	_env = null
	_have_prev = false


# Cycling the base airlock moves the player ~10 m in one frame. That is not walking: the odometer must not count it.
func _watch_base_airlock() -> void:
	if _moon == null:
		return
	var base := _moon.get_node_or_null("InteriorBase")
	if base == null:
		return
	for sig in ["entered", "exited"]:
		if base.has_signal(sig) and not base.is_connected(sig, _on_base_airlock):
			base.connect(sig, _on_base_airlock)


func _on_base_airlock() -> void:
	_have_prev = false


func _init_errors(rng: RandomNumberGenerator) -> void:
	var sign_ := 1.0 if rng.randf() < 0.5 else -1.0
	_gyro_bias_dps = sign_ * rng.randf_range(GYRO_BIAS_MIN_DEG_MIN, GYRO_BIAS_MAX_DEG_MIN) / 60.0
	_gyro_err_deg = rng.randf_range(-GYRO_START_ERR_DEG, GYRO_START_ERR_DEG)
	_gyro_corr_deg = 0.0
	_hdg_sigma0_deg = 2.0
	_foot_bias = rng.randf_range(-FOOT_BIAS_MAX, FOOT_BIAS_MAX)
	_wheel_bias = rng.randf_range(-WHEEL_BIAS_MAX, WHEEL_BIAS_MAX)
	_t_play = 0.0
	_t_fix = 0.0
	_t_sight = 0.0
	_briefed = false


func _init_position(rng: RandomNumberGenerator) -> void:
	var player := _player()
	if player == null:
		return
	var crash: Dictionary = _mc.get("crash", {})
	var near_crash := LandingSite.has_wreck() and LandingSite.distance_to_wreck(player.global_position) < 400.0
	if near_crash and not crash.is_empty():
		_est_lat = deg_to_rad(float(crash["lat_deg"]))
		_est_lon = deg_to_rad(float(crash["lon_deg"]))
		_fix_sigma_m = START_FIX_SIGMA_M
		_fix_label = "impact point (crash site)"
	else:
		var ll := _true_lonlat_rad(player)
		var dist := rng.randf_range(80.0, 200.0)
		var b := rng.randf_range(0.0, TAU)
		_est_lat = ll[1] + dist * cos(b) / _radius()
		_est_lon = ll[0] + dist * sin(b) / (_radius() * maxf(cos(ll[1]), 0.05))
		_fix_sigma_m = LOST_FIX_SIGMA_M
		_fix_label = "position lost: fix on a landmark"
	_since_fix_m = 0.0
	_trip_e = 0.0
	_trip_n = 0.0
	_t_fix = _t_play


func _brief() -> void:
	_briefed = true
	await get_tree().create_timer(5.0).timeout
	if not active:
		return
	Dialogue.say("Eagle, we have lost your beacon and cannot track you. We have the crash site, the base and three rover drop points on file.", 7.0, "Mission Control")
	Dialogue.say("Open your nav slate with N. Dead-reckon from the crash site, sight the Sun or Earth with G to check your gyro, and fix your position at the base or the crash site.", 8.0, "Mission Control")


# ================================================================= save

func get_state() -> Dictionary:
	return {
		"est_lat_deg": rad_to_deg(_est_lat), "est_lon_deg": rad_to_deg(_est_lon),
		"fix_sigma_m": _fix_sigma_m, "since_fix_m": _since_fix_m,
		"trip_e": _trip_e, "trip_n": _trip_n, "odo_m": _odo_total_m,
		"t_play": _t_play, "t_fix": _t_fix, "t_sight": _t_sight, "fix_label": _fix_label,
		"gyro_err_deg": _gyro_err_deg, "gyro_bias_dps": _gyro_bias_dps, "gyro_corr_deg": _gyro_corr_deg,
		"hdg_sigma0_deg": _hdg_sigma0_deg, "foot_bias": _foot_bias, "wheel_bias": _wheel_bias,
		"mc": _mc.duplicate(true), "uplinked": _uplinked.keys(), "briefed": _briefed,
	}


func _load_state(s: Dictionary) -> void:
	_est_lat = deg_to_rad(float(s.get("est_lat_deg", 0.0)))
	_est_lon = deg_to_rad(float(s.get("est_lon_deg", 0.0)))
	_fix_sigma_m = float(s.get("fix_sigma_m", LOST_FIX_SIGMA_M))
	_since_fix_m = float(s.get("since_fix_m", 0.0))
	_trip_e = float(s.get("trip_e", 0.0))
	_trip_n = float(s.get("trip_n", 0.0))
	_odo_total_m = float(s.get("odo_m", 0.0))
	_t_play = float(s.get("t_play", 0.0))
	_t_fix = float(s.get("t_fix", 0.0))
	_t_sight = float(s.get("t_sight", 0.0))
	_fix_label = str(s.get("fix_label", ""))
	_gyro_err_deg = float(s.get("gyro_err_deg", 0.0))
	_gyro_bias_dps = float(s.get("gyro_bias_dps", 0.0))
	_gyro_corr_deg = float(s.get("gyro_corr_deg", 0.0))
	_hdg_sigma0_deg = float(s.get("hdg_sigma0_deg", 2.0))
	_foot_bias = float(s.get("foot_bias", 0.0))
	_wheel_bias = float(s.get("wheel_bias", 0.0))
	var mc: Variant = s.get("mc", {})
	if mc is Dictionary:
		_mc = (mc as Dictionary).duplicate(true)
	for id in s.get("uplinked", []):
		_uplinked[str(id)] = true
	_briefed = bool(s.get("briefed", false))


# ================================================================= mission control sheet

func _build_mc() -> void:
	for spec in POINTS:
		var id := str(spec["id"])
		if _mc.has(id):
			continue
		var true_ll := _true_point_lonlat(spec)
		if true_ll.is_empty():
			continue
		var r := RandomNumberGenerator.new()
		r.seed = _save_seed + id.hash() * 31 + 17
		var dist := 0.0
		if str(spec["kind"]) == "drop":
			dist = r.randf_range(float(spec["min"]), float(spec["max"]))
		else:
			dist = absf(r.randfn(0.0, float(spec["sigma"])))
		var b := r.randf_range(0.0, TAU)
		var lat := deg_to_rad(true_ll[1])
		var lat2 := lat + dist * cos(b) / _radius()
		var lon2 := deg_to_rad(true_ll[0]) + dist * sin(b) / (_radius() * maxf(cos(lat), 0.05))
		_mc[id] = {"lon_deg": rad_to_deg(lon2), "lat_deg": rad_to_deg(lat2)}


func _true_point_lonlat(spec: Dictionary) -> PackedFloat64Array:
	if str(spec["id"]) == "crash":
		if LandingSite.has_wreck():
			return _lonlat_of_pos(LandingSite.wreck_pivot.global_position)
		return PackedFloat64Array([LandingSite.crater_lon_deg, LandingSite.crater_lat_deg])
	var n: Node3D = null
	if _moon != null:
		n = _moon.get_node_or_null(str(spec["node"])) as Node3D
	if n == null:
		return PackedFloat64Array()
	return _lonlat_of_pos(n.global_position)


func _refresh_unlocks(announce: bool) -> void:
	_build_mc()
	for spec in POINTS:
		var id := str(spec["id"])
		if _uplinked.has(id) or not _mc.has(id):
			continue
		var stage := str(spec["unlock"])
		if stage != "" and not Repairs.stage_complete(stage):
			continue
		_uplinked[id] = true
		if announce:
			Dialogue.say("New point uplinked to your nav slate: %s." % str(spec["name"]), 5.0, "Mission Control")
	mc_changed.emit()


func _on_stage_completed(_stage_id: String) -> void:
	if active:
		_refresh_unlocks(true)


## Rows for the slate: id, name, known, lon_deg, lat_deg, dispersion_m, note.
func point_rows() -> Array:
	var rows: Array = []
	for spec in POINTS:
		var id := str(spec["id"])
		var row := {"id": id, "name": str(spec["name"]), "known": false, "lon_deg": 0.0, "lat_deg": 0.0,
			"dispersion_m": 0.0, "note": ""}
		if _uplinked.has(id) and _mc.has(id):
			row["known"] = true
			row["lon_deg"] = float(_mc[id]["lon_deg"])
			row["lat_deg"] = float(_mc[id]["lat_deg"])
			if str(spec["kind"]) == "drop":
				row["dispersion_m"] = ceilf(float(spec["max"]) / 25.0) * 25.0
				var node_name := str(spec["node"])
				if node_name.begins_with("Rover") and Repairs.is_salvaged(node_name):
					row["note"] = "salvaged"
		else:
			var stage := str(spec["unlock"])
			row["note"] = "no data yet: finish \"%s\"" % Repairs.stage_name(stage) if stage != "" else "no data"
		rows.append(row)
	return rows


func point_row(id: String) -> Dictionary:
	for r in point_rows():
		if str(r["id"]) == id:
			return r
	return {}


# ================================================================= per frame

func _process(delta: float) -> void:
	_sight_cd = maxf(0.0, _sight_cd - delta)
	_range_cd = maxf(0.0, _range_cd - delta)


func _physics_process(delta: float) -> void:
	if not active:
		return
	if _moon == null or not is_instance_valid(_moon):
		end_session()
		return
	var player := _player()
	if player == null:
		return
	_t_play += delta
	# the gyro drifts whether or not you move
	_gyro_err_deg += _gyro_bias_dps * delta + randfn(0.0, GYRO_RANDOM_WALK) * sqrt(delta)
	_gyro_err_deg = clampf(_gyro_err_deg, -40.0, 40.0)

	var cur := _xyz(player)
	if cur.is_empty():
		return
	if _have_prev:
		var d := _enu_delta(_prev, cur)
		var dist := d.length()
		if dist > 0.0005 and dist < 60.0:
			_integrate(d, dist, delta, player)
	_prev = cur
	_have_prev = true
	_arrive_cd -= delta
	if _arrive_cd <= 0.0:
		_arrive_cd = 0.5
		_check_arrivals(player)


func _integrate(d: Vector2, dist: float, delta: float, player: MoonPlayer) -> void:
	var bearing := atan2(d.x, d.y)                      # clockwise from north
	var speed := dist / maxf(delta, 0.0001)
	var on_floor := player.is_on_floor()
	var slope := 0.0
	if on_floor:
		slope = acos(clampf(player.get_floor_normal().dot(player.up_direction), -1.0, 1.0))
	var path := dist / cos(minf(slope, deg_to_rad(40.0)))      # odometers measure path length, not horizontal distance
	var meas := 0.0
	if player.vehicle != null and is_instance_valid(player.vehicle):
		if on_floor:                                   # wheels in the air count nothing
			meas = path * (1.0 + WHEEL_SLIP_BASE + WHEEL_SLIP_PER_RAD * slope) * (1.0 + _wheel_bias)
	else:
		var gait := lerpf(1.03, 0.94, clampf((speed - 1.0) / 3.2, 0.0, 1.0))      # a pedometer is tuned for walking
		meas = path * gait * (1.0 + _foot_bias)
	if meas <= 0.0:
		return
	var h := bearing + deg_to_rad(_gyro_err_deg + _gyro_corr_deg)
	var dn := meas * cos(h)
	var de := meas * sin(h)
	_est_lat += dn / _radius()
	_est_lon += de / (_radius() * maxf(cos(_est_lat), 0.05))
	_trip_n += dn
	_trip_e += de
	_since_fix_m += meas
	_odo_total_m += meas


# ================================================================= estimate

func est_lat_deg() -> float:
	return rad_to_deg(_est_lat)


func est_lon_deg() -> float:
	return rad_to_deg(_est_lon)


func hdg_sigma_deg() -> float:
	var minutes := maxf(_t_play - _t_sight, 0.0) / 60.0
	return sqrt(_hdg_sigma0_deg * _hdg_sigma0_deg + pow(COMPUTER_DRIFT_DEG_MIN * minutes, 2.0))


func pos_sigma_m() -> float:
	var s := _since_fix_m
	var h := deg_to_rad(hdg_sigma_deg())
	return sqrt(_fix_sigma_m * _fix_sigma_m + pow(ODO_SIGMA_FRAC * s, 2.0) + pow(s * h, 2.0))


func since_fix_m() -> float:
	return _since_fix_m


func trip_east_m() -> float:
	return _trip_e


func trip_north_m() -> float:
	return _trip_n


func fix_label() -> String:
	return _fix_label


func fix_age_s() -> float:
	return maxf(_t_play - _t_fix, 0.0)


func sight_age_s() -> float:
	return maxf(_t_play - _t_sight, 0.0)


func meters_per_degree() -> float:
	return _radius() * PI / 180.0


## Heading the gyro shows for a world direction (degrees clockwise from north), 0..360.
func heading_deg_for(player: MoonPlayer, dir: Vector3) -> float:
	var ll := _true_lonlat_rad(player)
	var up := _up_v(ll[0], ll[1])
	var az := _az_of(dir, up, _east_v(ll[0]), _north_v(ll[0], ll[1]))
	if is_nan(az):
		return 0.0
	return fposmod(rad_to_deg(az) + _gyro_err_deg + _gyro_corr_deg, 360.0)


func hud_text(player: MoonPlayer) -> String:
	if not active:
		return ""
	var hd := heading_deg_for(player, -player.global_basis.z)
	var text := "NAV  heading %03d°   run %s   DR ±%s   [N] nav slate" % [
		int(round(hd)) % 360, fmt_dist(_since_fix_m), fmt_dist(pos_sigma_m())]
	if debug_truth:
		var ll := _true_lonlat_rad(player)
		text += "\nTRUTH lat %.5f lon %.5f   DR error %.0f m   gyro error %.2f°" % [
			rad_to_deg(ll[1]), rad_to_deg(ll[0]), _dr_error_m(ll), _gyro_err_deg + _gyro_corr_deg]
	return text


func _dr_error_m(ll: PackedFloat64Array) -> float:
	var dn := (_est_lat - ll[1]) * _radius()
	var de := (_est_lon - ll[0]) * _radius() * cos(ll[1])
	return sqrt(dn * dn + de * de)


static func fmt_dist(m: float) -> String:
	m = absf(m)
	if m >= 1000.0:
		return "%.2f km" % (m / 1000.0)
	return "%d m" % int(round(m))


func _unhandled_input(event: InputEvent) -> void:
	if not active or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if Inventory.ui_open:
		return
	match event.keycode:
		KEY_G:
			take_sight()
			get_viewport().set_input_as_handled()
		KEY_R:
			range_landmark()
			get_viewport().set_input_as_handled()
		KEY_F3:
			if OS.is_debug_build():
				debug_truth = not debug_truth


# ================================================================= fixes

func _apply_fix(lat: float, lon: float, sigma: float, label: String) -> void:
	var s_dr := maxf(pos_sigma_m(), 1.0)
	var s_fx := maxf(sigma, 1.0)
	var w := (s_dr * s_dr) / (s_dr * s_dr + s_fx * s_fx)            # inverse-variance blend
	_est_lat += w * (lat - _est_lat)
	_est_lon += w * (lon - _est_lon)
	_fix_sigma_m = sqrt(1.0 / (1.0 / (s_dr * s_dr) + 1.0 / (s_fx * s_fx)))
	_since_fix_m = 0.0
	_trip_e = 0.0
	_trip_n = 0.0
	_t_fix = _t_play
	_fix_label = label


## Slate button. Returns the message to show.
func fix_landmark(id: String) -> String:
	var p := _player()
	if p == null or not LANDMARKS.has(id):
		return "Nav computer offline."
	var lm: Dictionary = LANDMARKS[id]
	var mc: Dictionary = _mc.get(id, {})
	if mc.is_empty():
		return "Mission control has no coordinates for the %s." % str(lm["label"])
	if _distance_to_landmark(id, p) > float(lm["touch_m"]):
		return "Too far from the %s for a touch fix: get right up to it (within %d m)." % [str(lm["label"]), int(lm["touch_m"])]
	_apply_fix(deg_to_rad(float(mc["lat_deg"])), deg_to_rad(float(mc["lon_deg"])), float(lm["touch_sigma_m"]), "touch fix at the " + str(lm["label"]))
	return "Position fixed at the %s. Good to about ±%s." % [str(lm["label"]), fmt_dist(pos_sigma_m())]


func _distance_to_landmark(id: String, p: MoonPlayer) -> float:
	if id == "crash":
		return LandingSite.distance_to_wreck(p.global_position)
	var n := _landmark_node(id)
	if n == null:
		return INF
	return n.global_position.distance_to(p.global_position)


func _landmark_node(id: String) -> Node3D:
	if _moon == null:
		return null
	if id == "crash":
		return LandingSite.wreck_pivot if LandingSite.has_wreck() else null
	return _moon.get_node_or_null("InteriorBase") as Node3D


func take_sight() -> void:
	var p := _player()
	if p == null:
		return
	if _sight_cd > 0.0:
		_say("Sight computer busy: %d s." % int(ceil(_sight_cd)))
		return
	var env := _environment()
	if env == null:
		_say("No celestial reference available.")
		return
	var ll := _true_lonlat_rad(p)
	var up := _up_v(ll[0], ll[1])
	var east := _east_v(ll[0])
	var north := _north_v(ll[0], ll[1])
	var fwd := -p.camera.global_basis.z
	var bodies: Array = [["Sun", env.get_sun_direction(), 0.35]]
	if env.earth_enabled:
		bodies.append(["Earth", env.get_earth_direction(), 0.6])
	var best_name := ""
	var best_dir := Vector3.ZERO
	var best_ang := 999.0
	var best_elev := 0.0
	var best_sigma := 0.35
	var any_up := false
	for b in bodies:
		var dir: Vector3 = b[1]
		var elev := rad_to_deg(asin(clampf(up.dot(dir), -1.0, 1.0)))
		if elev < 3.0:
			continue
		any_up = true
		var ang := rad_to_deg(acos(clampf(fwd.dot(dir), -1.0, 1.0)))
		if ang < best_ang:
			best_ang = ang
			best_name = str(b[0])
			best_dir = dir
			best_elev = elev
			best_sigma = float(b[2])
	if not any_up:
		_say("No Sun or Earth above the horizon: no celestial reference.")
		return
	if best_ang > SIGHT_CONE_DEG:
		_say("Centre the Sun or the Earth in the crosshair (within %d°), then press G." % int(SIGHT_CONE_DEG))
		return
	if best_elev > MAX_SIGHT_ELEV_DEG:
		_say("The %s is too near the zenith for an azimuth sight." % best_name)
		return
	var az_cam := rad_to_deg(_az_of(fwd, up, east, north)) + randfn(0.0, 0.10)
	var u_est := _up_v(_est_lon, _est_lat)
	var az_eph := rad_to_deg(_az_of(best_dir, u_est, _east_v(_est_lon), _north_v(_est_lon, _est_lat)))
	var old := _gyro_corr_deg
	_gyro_corr_deg = wrapf(az_eph - az_cam - _gyro_err_deg, -180.0, 180.0)
	var delta := wrapf(_gyro_corr_deg - old, -180.0, 180.0)
	_hdg_sigma0_deg = best_sigma
	_t_sight = _t_play
	_sight_cd = SIGHT_COOLDOWN_S
	_say("%s sight taken: gyro corrected by %+.1f°. Heading good to about ±%.1f°." % [best_name, delta, _hdg_sigma0_deg])


func range_landmark() -> void:
	var p := _player()
	if p == null:
		return
	if _range_cd > 0.0:
		return
	var cam := p.camera
	var fwd := -cam.global_basis.z
	var cam_pos := cam.global_position
	var best_id := ""
	var best_ang := 999.0
	var best_range := 0.0
	for id in LANDMARKS:
		var n := _landmark_node(str(id))
		if n == null:
			continue
		var v := n.global_position - cam_pos
		var d := v.length()
		if d < 1.0:
			continue
		var ang := rad_to_deg(acos(clampf(fwd.dot(v / d), -1.0, 1.0)))
		if ang < best_ang:
			best_ang = ang
			best_id = str(id)
			best_range = d
	_range_cd = RANGE_COOLDOWN_S
	if best_id == "" or best_ang > RANGE_CONE_DEG:
		_say("Rangefinder: no known landmark in the crosshair (the crash site and the base are on file).")
		return
	var lm: Dictionary = LANDMARKS[best_id]
	var label := str(lm["label"])
	if best_range < 30.0:
		_say("Too close to range the %s: use a touch fix." % label)
		return
	var R := _radius()
	var horizon := sqrt(2.0 * R * p.eye_height) + sqrt(2.0 * R * float(lm["height_m"]))
	if best_range > horizon:
		_say("The %s is below the horizon." % label)
		return
	var node := _landmark_node(best_id)
	if best_range < 1400.0 and not _line_of_sight(p, cam_pos, node):
		_say("Line of sight to the %s is blocked." % label)
		return
	var mc: Dictionary = _mc.get(best_id, {})
	if mc.is_empty():
		_say("Mission control has no coordinates for the %s." % label)
		return
	var ll := _true_lonlat_rad(p)
	var up := _up_v(ll[0], ll[1])
	var pitch := asin(clampf(fwd.dot(up), -1.0, 1.0))
	var meas_range := best_range * (1.0 + randfn(0.0, 0.004)) + randfn(0.0, 0.8)
	var h_range := meas_range * cos(pitch)
	var az_cam := rad_to_deg(_az_of(fwd, up, _east_v(ll[0]), _north_v(ll[0], ll[1])))
	var az := deg_to_rad(az_cam + _gyro_err_deg + _gyro_corr_deg)        # what the gyro shows for the sight line
	var lm_lat := deg_to_rad(float(mc["lat_deg"]))
	var lm_lon := deg_to_rad(float(mc["lon_deg"]))
	var f_lat := lm_lat - h_range * cos(az) / R
	var f_lon := lm_lon - h_range * sin(az) / (R * maxf(cos(lm_lat), 0.05))
	var sigma := sqrt(pow(0.006 * best_range + 1.0, 2.0)
		+ pow(h_range * deg_to_rad(hdg_sigma_deg() + 0.3), 2.0)
		+ pow(float(lm["mc_sigma_m"]), 2.0) + pow(float(lm["extent_m"]), 2.0))
	_apply_fix(f_lat, f_lon, sigma, "range to the " + label)
	_say("Range fix on the %s: %d m, bearing %03d°. Position good to about ±%s." % [
		label, int(round(h_range)), int(round(fposmod(rad_to_deg(az), 360.0))) % 360, fmt_dist(pos_sigma_m())])


func _line_of_sight(p: MoonPlayer, from: Vector3, node: Node3D) -> bool:
	var space := p.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, node.global_position + p.up_direction * 3.0)
	q.exclude = [p.get_rid()]
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return true
	var c := hit["collider"] as Node
	while c != null:
		if c == node:
			return true
		c = c.get_parent()
	return false


# ================================================================= sky + plotter helpers

## Sun / Earth az + el at the DR position, plus their sub-points (from the ephemeris mission control publishes).
func sky_prediction() -> Dictionary:
	var env := _environment()
	if env == null:
		return {}
	var out := {}
	var u := _up_v(_est_lon, _est_lat)
	var e := _east_v(_est_lon)
	var n := _north_v(_est_lon, _est_lat)
	var bodies := {"sun": env.get_sun_direction(), "earth": env.get_earth_direction()}
	for k in bodies:
		var dir: Vector3 = bodies[k]
		out[k] = {
			"az": fposmod(rad_to_deg(_az_of(dir, u, e, n)), 360.0),
			"el": rad_to_deg(asin(clampf(u.dot(dir), -1.0, 1.0))),
			"lat": rad_to_deg(asin(clampf(dir.y, -1.0, 1.0))),
			"lon": rad_to_deg(atan2(dir.x, dir.z)),
		}
	return out


## Range and bearing between two lat / lon points (degrees), by the player's inputs.
func solve(lat1: float, lon1: float, lat2: float, lon2: float) -> Dictionary:
	var R := _radius()
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dl := deg_to_rad(lon2 - lon1)
	var a := pow(sin((p2 - p1) * 0.5), 2.0) + cos(p1) * cos(p2) * pow(sin(dl * 0.5), 2.0)
	var d := 2.0 * R * asin(minf(sqrt(a), 1.0))
	var y := sin(dl) * cos(p2)
	var x := cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
	return {
		"range_m": d,
		"bearing_deg": fposmod(rad_to_deg(atan2(y, x)), 360.0),
		"north_m": (p2 - p1) * R,
		"east_m": dl * R * cos((p1 + p2) * 0.5),
	}


# ================================================================= mission control on the move

## The id of the slate point whose object is the scene node with this name ("Rover1_2" -> "drop_b"), or "".
func point_id_for_node(node_name: String) -> String:
	for spec in POINTS:
		if str(spec["node"]) == node_name:
			return str(spec["id"])
	return ""


## "640 m on bearing 213": range and bearing from one slate point to another, worked out from the PUBLISHED positions
## only (all mission control has, never the true ones). "" unless both points have been uplinked.
func published_leg(from_id: String, to_id: String) -> String:
	if not (_uplinked.has(from_id) and _uplinked.has(to_id) and _mc.has(from_id) and _mc.has(to_id)):
		return ""
	var a: Dictionary = _mc[from_id]
	var b: Dictionary = _mc[to_id]
	var s := solve(float(a["lat_deg"]), float(a["lon_deg"]), float(b["lat_deg"]), float(b["lon_deg"]))
	return "%s on bearing %03d" % [fmt_dist(float(s["range_m"])), int(round(float(s["bearing_deg"]))) % 360]


# Twice a second: coming across the first rover wreck, and reaching the return spacecraft, each start a short
# exchange, once per game (remembered in the slot).
func _check_arrivals(player: MoonPlayer) -> void:
	if _moon == null or not is_instance_valid(_moon):
		return
	if not Repairs.has_flag(FLAG_ROVER_FOUND):
		for node_name in ["Rover1_1", "Rover1_2", "Rover1_3"]:
			var rover := _moon.get_node_or_null(str(node_name)) as Node3D
			if rover != null and rover.global_position.distance_to(player.global_position) <= ARRIVE_ROVER_M:
				Repairs.set_flag(FLAG_ROVER_FOUND)
				_rover_found(str(node_name))
				break
	if not Repairs.has_flag(FLAG_ROCKET_FOUND):
		var rocket := _moon.get_node_or_null("ReturnRocket") as Node3D
		if rocket != null and rocket.global_position.distance_to(player.global_position) <= ARRIVE_ROCKET_M:
			Repairs.set_flag(FLAG_ROCKET_FOUND)
			_rocket_found()


func _rover_found(node_name: String) -> void:
	Dialogue.say("The rover is damaged. I'll need to inspect its systems.", 0.0, "Astronaut")
	Dialogue.say("Vehicle diagnostics indicate multiple damaged components.", 0.0, "Suit computer")
	var id := point_id_for_node(node_name)
	var row := point_row(id)
	if row.is_empty() or not bool(row["known"]):
		return
	var short_name := str(row["name"]).get_slice(" (", 0)
	Dialogue.say("Copy, Eagle. If that is one of the rovers, it matches %s on our sheet, which is only good to about %d m." % [short_name, int(row["dispersion_m"])], 0.0, "Mission Control")
	var leg := published_leg(id, "base")
	if leg != "":
		Dialogue.say("From that point the base is %s. Dead-reckon back along it, and re-fix on the base to clear the drift." % leg, 0.0, "Mission Control")


func _rocket_found() -> void:
	Dialogue.say("There's the return spacecraft. Now I need to check the damage.", 0.0, "Astronaut")
	Dialogue.say("Spacecraft inspection initiated.", 0.0, "Suit computer")
	var row := point_row("drop_rocket")
	if row.is_empty() or not bool(row["known"]):
		Dialogue.say("That position is not on our sheet yet, Eagle. We will uplink the landing point once the buggy is repaired. Until then, note where it is by dead reckoning.", 0.0, "Mission Control")
		return
	var leg := published_leg("drop_rocket", "base")
	if leg != "":
		Dialogue.say("Copy, Eagle. That is the landing point on your slate, published to about %d m. From there the base is %s. That is your fuel-run route, so learn it." % [int(row["dispersion_m"]), leg], 0.0, "Mission Control")


# ================================================================= internals

func _say(text: String) -> void:
	event_logged.emit(text)
	Dialogue.say(text, 4.5, "Nav computer")


func _player() -> MoonPlayer:
	if _moon == null or not is_instance_valid(_moon):
		return null
	var p := _moon.player as MoonPlayer
	if p == null or not is_instance_valid(p):
		return null
	return p


func _radius() -> float:
	if _moon != null and is_instance_valid(_moon):
		return _moon.planet_radius_m
	return FALLBACK_RADIUS_M


func _environment() -> LunarEnvironment:
	if _env != null and is_instance_valid(_env):
		return _env
	_env = _find_env(get_tree().root)
	return _env


func _find_env(n: Node) -> LunarEnvironment:
	if n is LunarEnvironment:
		return n as LunarEnvironment
	for c in n.get_children():
		var r := _find_env(c)
		if r != null:
			return r
	return null


# planet-centred position of a world position / of the player, in doubles
func _xyz_of_pos(gp: Vector3) -> PackedFloat64Array:
	var off: Array = _moon._off
	return PackedFloat64Array([float(off[0]) + gp.x, float(off[1]) + gp.y, float(off[2]) + gp.z])


func _xyz(player: Node3D) -> PackedFloat64Array:
	return _xyz_of_pos(player.global_position)


func _lonlat_of_pos(gp: Vector3) -> PackedFloat64Array:
	var c := _xyz_of_pos(gp)
	var r := sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2])
	if r < 1.0:
		return PackedFloat64Array()
	return PackedFloat64Array([rad_to_deg(atan2(c[0], c[2])), rad_to_deg(asin(clampf(c[1] / r, -1.0, 1.0)))])


## [lon, lat] in radians of the player's true position.
func _true_lonlat_rad(player: Node3D) -> PackedFloat64Array:
	var c := _xyz(player)
	var r := maxf(sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2]), 1.0)
	return PackedFloat64Array([atan2(c[0], c[2]), asin(clampf(c[1] / r, -1.0, 1.0))])


# (east, north) metres between two planet-centred positions, at the second one
func _enu_delta(a: PackedFloat64Array, b: PackedFloat64Array) -> Vector2:
	var r := maxf(sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]), 1.0)
	var lon := atan2(b[0], b[2])
	var lat := asin(clampf(b[1] / r, -1.0, 1.0))
	var dx := b[0] - a[0]
	var dy := b[1] - a[1]
	var dz := b[2] - a[2]
	var de := dx * cos(lon) - dz * sin(lon)
	var dn := -dx * sin(lat) * sin(lon) + dy * cos(lat) - dz * sin(lat) * cos(lon)
	return Vector2(de, dn)


static func _up_v(lon: float, lat: float) -> Vector3:
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


static func _east_v(lon: float) -> Vector3:
	return Vector3(cos(lon), 0.0, -sin(lon))


static func _north_v(lon: float, lat: float) -> Vector3:
	return Vector3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))


# azimuth (radians, clockwise from north) of a direction as seen by an observer with this up / east / north
static func _az_of(dir: Vector3, up: Vector3, east: Vector3, north: Vector3) -> float:
	var h := dir - up * dir.dot(up)
	if h.length_squared() < 1e-10:
		return NAN
	return atan2(h.dot(east), h.dot(north))
