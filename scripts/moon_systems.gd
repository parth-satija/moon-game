extends Node
## Autoload "MoonSystems": plugs the radio network (moon_comms.gd) and the heat model (moon_thermal.gd) into the game.
##
## COMMUNICATIONS
##   Radios: the lunar base (the only dish that can reach Earth), the emergency relay mast on the crashed Starship and
##   the player's suit radio (stronger in the buggy). MoonComms works out the link budget of every pair about twice a
##   second: free-space loss, diffraction over the horizon and the heightmap, receiver noise, and electronics that are
##   too hot or too cold to transmit at full power. The weakest hop of the best route to Earth gives the link quality
##   (0..1) that the Dialogue autoload uses to garble Mission Control: the weaker the signal, the more of each line is
##   lost to static. Inside the base the link is always clean. If Earth is below the horizon (far side) or behind
##   terrain, a relay satellite gives a weak fallback instead of silence.
##
## TEMPERATURE
##   MoonThermal heats and cools the regolith and the suit, using the Sun the player sees in the sky. The suit has a
##   thermal reserve. While the suit is outside its comfort band the reserve drains (faster the worse the extreme:
##   noon sun, the lunar night); inside the band it slowly recovers; inside the base it recovers fast. At zero the
##   player collapses and wakes up in the base. Shade (anything that blocks the Sun, found with a ray) takes the solar
##   load off the suit. An unrepaired suit electrical system makes the suit's thermal control weaker.
##
## Hooks used by GameState: begin_session(slot_state, moon), get_state(), end_session().
## Debug builds: F7 moves the Sun 45 degrees west, to reach noon or night without waiting.
##
##     MoonSystems.quality        0..1, the link quality Dialogue is using right now
##     MoonSystems.reserve        0..1, the suit's thermal reserve
##     MoonSystems.thermal        the MoonThermal node (null outside a session)
##     MoonSystems.comms          the MoonComms node (null outside a session)

signal collapsed(hot: bool)

const PLAYER := &"player"
const BASE := &"base"
const WRECK := &"wreck"
const SUIT := &"suit"
const BASE_RADIO := &"base_radio"
const WRECK_RADIO := &"wreck_radio"

# ---- world ------------------------------------------------------------------------------------------------------
## true: if the scene's LunarEnvironment has its day cycle off, switch it on (one lunar day = DAY_REAL_SECONDS), so
## that noon heat and night cold come and go by themselves. false: use the Sun exactly as the scene sets it.
const FORCE_DAY_CYCLE := false
const DAY_REAL_SECONDS := 1200.0
## An emergency relay mast on the wreck, so the landing area has coverage even when the base is far away.
const WRECK_RELAY := true
const DEBUG_SUN_KEY := KEY_F7
const DEBUG_SUN_STEP_DEG := 45.0
const SHADE_RAY_M := 400.0
const SHADE_INTERVAL_S := 0.25

# ---- comms ------------------------------------------------------------------------------------------------------
const PLAYER_RADIO := {"mast_m": 1.9, "tx_dbm": 33.0, "gain_dbi": 4.0}
const BUGGY_RADIO := {"mast_m": 2.6, "tx_dbm": 37.0, "gain_dbi": 8.0}
const TRACK_INTERVAL_S := 0.25
const QUALITY_RATE := 4.0                        # how fast the garbling follows the signal (1/s)
const NODE_NAMES := {&"base": "base", &"wreck": "crash relay", &"EARTH": "Earth"}

# ---- thermal equipment (see MoonThermal.Equipment) ----------------------------------------------------------------
const SUIT_PROPS := {
	"mass_kg": 40.0, "cp_j_kgk": 900.0, "area_m2": 1.8, "absorptivity": 0.2, "emissivity": 0.85,
	"internal_w": 120.0, "heater_w": 80.0, "heater_on_k": 255.0, "max_k": 335.0, "min_k": 235.0, "temp_k": 295.0,
}
const BASE_RADIO_PROPS := {
	"mass_kg": 25.0, "cp_j_kgk": 900.0, "area_m2": 0.5, "absorptivity": 0.25, "emissivity": 0.85,
	"internal_w": 6.0, "heater_w": 0.0, "heater_on_k": 255.0, "max_k": 345.0, "min_k": 225.0, "temp_k": 285.0,
}
const WRECK_RADIO_EQ := {
	"mass_kg": 25.0, "cp_j_kgk": 900.0, "area_m2": 0.5, "absorptivity": 0.25, "emissivity": 0.85,
	"internal_w": 22.0, "heater_w": 0.0, "heater_on_k": 255.0, "max_k": 345.0, "min_k": 225.0, "temp_k": 285.0,
}
const BASE_POWERED_W := 30.0                     # base radio electronics, with the base power restored
const BASE_HEATER_W := 40.0
const BASE_DEAD_W := 6.0

# ---- suit thermal reserve ---------------------------------------------------------------------------------------
const COMFORT_HOT_K := 315.0                     # suit temperature above this drains the reserve
const COMFORT_COLD_K := 245.0                    # ... and below this
const SHELTER_TEMP_K := 295.0
## Reserve drained per second (fraction of a full reserve) against how many kelvin outside the comfort band.
const HOT_CURVE := [Vector2(0.0, 0.0), Vector2(10.0, 1.0 / 600.0), Vector2(25.0, 1.0 / 240.0),
	Vector2(45.0, 1.0 / 100.0), Vector2(75.0, 1.0 / 50.0)]
const COLD_CURVE := [Vector2(0.0, 0.0), Vector2(15.0, 1.0 / 1200.0), Vector2(35.0, 1.0 / 480.0),
	Vector2(65.0, 1.0 / 240.0), Vector2(125.0, 1.0 / 120.0)]
const RECOVER_OUTSIDE := 1.0 / 240.0             # per second, inside the comfort band
const RECOVER_SHELTER := 1.0 / 45.0              # per second, inside the base
const BUGGY_FACTOR := 0.7                        # the buggy shades you a little
const POWER_FAULT_FACTOR := 1.5                  # suit electrics unrepaired: weaker thermal control
const WAKE_RESERVE := 0.5
const WARN_LEVELS := [0.75, 0.4, 0.15]

const COL_TEXT := Color(0.93, 0.95, 1.0)
const COL_DIM := Color(0.62, 0.68, 0.78)
const COL_WARN := Color(1.0, 0.7, 0.25)
const COL_CRIT := Color(1.0, 0.3, 0.28)
const COL_RESERVE := Color(0.45, 0.85, 0.6)

var thermal: MoonThermal
var comms: MoonComms
var active := false
var quality := 1.0
var reserve := 1.0
var collapses := 0
## Set while something else owns the screen (a cutscene): the suit stops ticking.
var suspended := false
var hud_hidden := false

var _moon: MoonPlanet
var _env: LunarEnvironment
var _base: Node3D
var _have_comms := false
var _ref_lat := 0.0                               # radians: the comms frame is centred on the base
var _ref_lon := 0.0
var _shaded := false
var _ray_cd := 0.0
var _radio_cd := 0.0
var _power_cd := 0.0
var _in_buggy := false
var _sheltered := false
var _suit_k := 295.0
var _kind := 0                                    # 1 = draining from heat, -1 = from cold, 0 = fine
var _warn_level := 0
var _collapsing := false

var _layer: CanvasLayer
var _panel: PanelContainer
var _comms_label: Label
var _comms_note: Label
var _suit_label: Label
var _reserve_label: Label
var _reserve_fill: ColorRect
var _suit_note: Label


func _ready() -> void:
	_build_hud()


# ================================================================= session

func begin_session(state: Dictionary, moon: MoonPlanet) -> void:
	end_session()
	_moon = moon
	set_state(state)
	var p := _player()
	if p == null:
		return
	_env = _find_env(get_tree().root)
	_base = moon.get_node_or_null("InteriorBase") as Node3D
	var ref: PackedFloat64Array
	if _base != null:
		ref = _lonlat_rad(_base.global_position)
	else:
		ref = PackedFloat64Array([deg_to_rad(LandingSite.lon_deg), deg_to_rad(LandingSite.lat_deg)])
	_ref_lon = ref[0]
	_ref_lat = ref[1]
	var wreck_ok := WRECK_RELAY and LandingSite.has_wreck()
	_build_thermal(p, wreck_ok)
	_build_comms(p, wreck_ok)
	_refresh_power()
	_ray_cd = 0.0
	_radio_cd = 0.0
	_power_cd = 1.0
	_shaded = false
	_in_buggy = false
	_sheltered = false
	_kind = 0
	active = true
	_track_player(p)


func end_session() -> void:
	active = false
	if thermal != null and is_instance_valid(thermal):
		thermal.queue_free()
	if comms != null and is_instance_valid(comms):
		comms.queue_free()
	thermal = null
	comms = null
	_moon = null
	_env = null
	_base = null
	_have_comms = false
	_collapsing = false
	suspended = false
	quality = 1.0
	Dialogue.signal_quality = 1.0


func get_state() -> Dictionary:
	if not active:
		return {}
	return {"reserve": reserve, "collapses": collapses}


func set_state(state: Dictionary) -> void:
	reserve = clampf(float(state.get("reserve", 1.0)), 0.0, 1.0)
	collapses = int(state.get("collapses", 0))
	_warn_level = 0


func _build_thermal(p: MoonPlayer, wreck_ok: bool) -> void:
	thermal = MoonThermal.new()
	thermal.name = "Thermal"
	if _env != null:
		thermal.sun_feed = Callable(self, "_sun_dir")        # the ground feels the Sun the player sees
		if FORCE_DAY_CYCLE and not _env.day_cycle_enabled:
			_env.lunar_day_seconds = DAY_REAL_SECONDS
			_env.day_cycle_enabled = true
		if _env.day_cycle_enabled:
			thermal.time_scale = MoonThermal.SYNODIC_DAY_S / maxf(_env.lunar_day_seconds, 30.0)
	add_child(thermal)
	var pl := _lonlat_rad(p.global_position)
	thermal.add_probe(PLAYER, rad_to_deg(pl[1]), rad_to_deg(pl[0]), 0.07, Vector3.UP, Callable(self, "_player_shaded"))
	thermal.add_equipment(SUIT, PLAYER, SUIT_PROPS)
	if _base != null:
		var bl := _lonlat_rad(_base.global_position)
		thermal.add_probe(BASE, rad_to_deg(bl[1]), rad_to_deg(bl[0]))
		thermal.add_equipment(BASE_RADIO, BASE, BASE_RADIO_PROPS)
	if wreck_ok:
		var wl := _lonlat_rad(LandingSite.wreck_pivot.global_position)
		thermal.add_probe(WRECK, rad_to_deg(wl[1]), rad_to_deg(wl[0]))
		thermal.add_equipment(WRECK_RADIO, WRECK, WRECK_RADIO_EQ)


func _build_comms(p: MoonPlayer, wreck_ok: bool) -> void:
	_have_comms = _base != null                      # without the base's dish nothing can reach Earth: no garbling
	comms = MoonComms.new()
	comms.name = "Comms"
	comms.thermal = thermal                          # shares the clock, and hot / frozen radios lose power
	comms.update_interval_s = 0.4
	comms.max_samples = 64
	comms.max_link_km = 60.0
	comms.horizon_step_m = 400.0
	comms.orbital_relay_enabled = true               # far side or masked Earth: a weak relay-satellite link
	comms.center_lat_deg = rad_to_deg(_ref_lat)
	comms.center_lon_deg = rad_to_deg(_ref_lon)
	comms.height_provider = Callable(self, "_terrain_height")
	add_child(comms)
	if not _have_comms:
		return
	comms.add_radio(BASE, MoonComms.Kind.SURFACE, _comms_pos(_base.global_position), {"equipment_id": BASE_RADIO})
	if wreck_ok:
		comms.add_radio(WRECK, MoonComms.Kind.RELAY, _comms_pos(LandingSite.wreck_pivot.global_position),
			{"dte_capable": false, "equipment_id": WRECK_RADIO})
	var props := PLAYER_RADIO.duplicate()
	props["equipment_id"] = SUIT
	comms.add_radio(PLAYER, MoonComms.Kind.ROVER, _comms_pos(p.global_position), props)


# ================================================================= per frame

func _physics_process(delta: float) -> void:
	if not active:
		return
	if _moon == null or not is_instance_valid(_moon):
		end_session()
		return
	var p := _player()
	if p == null:
		return
	_ray_cd -= delta
	if _ray_cd <= 0.0:
		_ray_cd = SHADE_INTERVAL_S
		_shaded = _cast_shade(p)
	_radio_cd -= delta
	if _radio_cd <= 0.0:
		_radio_cd = TRACK_INTERVAL_S
		_track_player(p)
	_power_cd -= delta
	if _power_cd <= 0.0:
		_power_cd = 1.0
		_refresh_power()
	if not suspended:
		_tick_suit(delta, p)


func _process(delta: float) -> void:
	var show := active and not hud_hidden
	_layer.visible = show
	if not active:
		return
	var target := 1.0
	if _have_comms and comms != null:
		target = comms.link_quality(PLAYER)
	quality = lerpf(quality, target, 1.0 - exp(-QUALITY_RATE * delta))
	Dialogue.signal_quality = quality
	if show:
		_update_hud()


## Keeps the thermal probe and the suit radio on the player (and in the base's own link while indoors).
func _track_player(p: MoonPlayer) -> void:
	var ll := _lonlat_rad(p.global_position)
	thermal.move_probe(PLAYER, rad_to_deg(ll[1]), rad_to_deg(ll[0]))
	if not _have_comms:
		return
	var in_buggy := p.vehicle != null and is_instance_valid(p.vehicle)
	if in_buggy != _in_buggy:
		_in_buggy = in_buggy
		comms.set_radio_props(PLAYER, BUGGY_RADIO if in_buggy else PLAYER_RADIO)
	var at := _base.global_position if _inside_base() else p.global_position
	comms.move_radio(PLAYER, _comms_pos(at))


## The base's radio electronics are only kept warm while the base has power.
func _refresh_power() -> void:
	if thermal == null:
		return
	var e := thermal.get_equipment(BASE_RADIO)
	if e == null:
		return
	var on := Repairs.stage_complete("base")
	e.internal_w = BASE_POWERED_W if on else BASE_DEAD_W
	e.heater_w = BASE_HEATER_W if on else 0.0


# ================================================================= suit

func _tick_suit(delta: float, p: MoonPlayer) -> void:
	var eq := thermal.get_equipment(SUIT)
	if eq == null:
		return
	_sheltered = _inside_base()
	if _sheltered:
		eq.temp_k = lerpf(eq.temp_k, SHELTER_TEMP_K, 1.0 - exp(-2.0 * delta))
	_suit_k = eq.temp_k
	var hot := _suit_k > COMFORT_HOT_K
	var cold := _suit_k < COMFORT_COLD_K
	var drain := 0.0
	if not _sheltered:
		if hot:
			drain = _curve(HOT_CURVE, _suit_k - COMFORT_HOT_K)
		elif cold:
			drain = _curve(COLD_CURVE, COMFORT_COLD_K - _suit_k)
	var fault := not Repairs.is_done("suit_electrical")
	if p.vehicle != null:
		drain *= BUGGY_FACTOR
	if fault:
		drain *= POWER_FAULT_FACTOR
	var recover := 0.0
	if drain <= 0.0:
		recover = RECOVER_SHELTER if _sheltered else RECOVER_OUTSIDE
		if fault:
			recover *= 0.5
	_kind = 0
	if drain > 0.0:
		_kind = 1 if hot else -1
	reserve = clampf(reserve + (recover - drain) * delta, 0.0, 1.0)

	var level := 0
	for i in WARN_LEVELS.size():
		if reserve <= float(WARN_LEVELS[i]):
			level = i + 1
	if drain > 0.0 and level > _warn_level:
		_warn_level = level
		_say_warning(hot, level)
	elif reserve >= 0.9:
		_warn_level = 0
	if reserve <= 0.0:
		_collapse(p, hot)


func _say_warning(hot: bool, level: int) -> void:
	var pct := int(round(reserve * 100.0))
	var text := ""
	if hot:
		match level:
			1: text = "Suit running hot. Thermal reserve at %d%%. Shade or the base will let it recover." % pct
			2: text = "Heat stress building. Thermal reserve at %d%%. Get out of the sun." % pct
			_: text = "Heat stress critical! Get into shade or the base now."
	else:
		match level:
			1: text = "Suit running cold. Thermal reserve at %d%%. The base will warm it back up." % pct
			2: text = "Cold stress building. Thermal reserve at %d%%. Head for the base." % pct
			_: text = "Cold stress critical! Get to the base now."
	Dialogue.say(text, 4.5, "Suit computer", level >= 3)


func _collapse(p: MoonPlayer, hot: bool) -> void:
	if _collapsing:
		return
	_collapsing = true
	suspended = true
	collapses += 1
	collapsed.emit(hot)
	Dialogue.say("Heat stroke. Everything goes dark..." if hot else "Hypothermia. Everything goes dark...", 3.0, "Suit computer", true)

	var layer := CanvasLayer.new()
	layer.layer = 61
	var rect := ColorRect.new()
	rect.color = Color(0, 0, 0, 0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	add_child(layer)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 1.0, 1.4)
	tw.tween_callback(_wake.bind(p, hot))
	tw.tween_interval(1.2)
	tw.tween_property(rect, "color:a", 0.0, 1.0)
	tw.tween_callback(func() -> void:
		layer.queue_free()
		suspended = false
		_collapsing = false)


# Mission control's recovery drones carry the player into the base. The buggy stays where it was.
func _wake(p: MoonPlayer, hot: bool) -> void:
	if not is_instance_valid(p):
		return
	if p.vehicle != null and is_instance_valid(p.vehicle) and p.vehicle.has_method("dismount"):
		p.vehicle.call("dismount")
	reserve = WAKE_RESERVE
	_warn_level = 1
	if thermal != null:
		var eq := thermal.get_equipment(SUIT)
		if eq != null:
			eq.temp_k = SHELTER_TEMP_K
	if _base != null and is_instance_valid(_base) and _base.has_method("enter_instantly"):
		_base.call("enter_instantly", p)
		Dialogue.say("You come round on the base floor. Recovery drones dragged you in out of the %s. The suit is stabilising." % ("heat" if hot else "cold"), 6.0, "Suit computer")
	else:
		Dialogue.say("You come round with the suit on reserve. Find shelter.", 5.0, "Suit computer")


static func _curve(points: Array, x: float) -> float:
	if x <= 0.0:
		return 0.0
	for i in range(1, points.size()):
		var b: Vector2 = points[i]
		if x <= b.x:
			var a: Vector2 = points[i - 1]
			return lerpf(a.y, b.y, (x - a.x) / maxf(b.x - a.x, 0.0001))
	var last: Vector2 = points[points.size() - 1]
	return last.y


# ================================================================= callbacks for the modules

## The Sun in the planet frame: the one in the player's sky.
func _sun_dir() -> Vector3:
	if _env != null and is_instance_valid(_env):
		return _env.get_sun_direction()
	return Vector3.UP


## MoonThermal asks this when the Sun is above the horizon; the answer is the ray cast done in _physics_process.
func _player_shaded(_sun_local: Vector3) -> bool:
	return _shaded


func _cast_shade(p: MoonPlayer) -> bool:
	var sun := _sun_dir()
	var up := p.up_direction
	if sun.dot(up) <= 0.0:
		return false
	var from := p.global_position + up * 1.0
	var q := PhysicsRayQueryParameters3D.create(from, from + sun * SHADE_RAY_M)
	var exclude: Array[RID] = [p.get_rid()]
	if p.vehicle is CollisionObject3D and is_instance_valid(p.vehicle):
		exclude.append((p.vehicle as CollisionObject3D).get_rid())
	q.exclude = exclude
	q.collide_with_areas = false
	return not p.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


## MoonComms asks this for the terrain under a point of its flat frame (metres east / north of the base).
func _terrain_height(east: float, north: float) -> float:
	if _moon == null or not is_instance_valid(_moon):
		return 0.0
	var r := _moon.planet_radius_m
	var lat := _ref_lat + north / r
	var lon := _ref_lon + east / (r * maxf(cos(lat), 0.01))
	var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	return _moon._sample_m(dir) - r


# ================================================================= geometry helpers

func _player() -> MoonPlayer:
	if _moon == null or not is_instance_valid(_moon):
		return null
	var p := _moon.player as MoonPlayer
	if p == null or not is_instance_valid(p):
		return null
	return p


func _inside_base() -> bool:
	return _base != null and is_instance_valid(_base) and bool(_base.get("player_inside"))


## [lon, lat] in radians of a world position, in doubles (the engine origin floats, see moon.gd).
func _lonlat_rad(gp: Vector3) -> PackedFloat64Array:
	var off: Array = _moon._off
	var x: float = float(off[0]) + gp.x
	var y: float = float(off[1]) + gp.y
	var z: float = float(off[2]) + gp.z
	var r := sqrt(x * x + y * y + z * z)
	if r < 1.0:
		return PackedFloat64Array([0.0, 0.0])
	return PackedFloat64Array([atan2(x, z), asin(clampf(y / r, -1.0, 1.0))])


## Metres east / north of the base.
func _enu(ll: PackedFloat64Array) -> Vector2:
	var r := _moon.planet_radius_m
	var dlon := wrapf(ll[0] - _ref_lon, -PI, PI)
	return Vector2(dlon * r * cos(0.5 * (ll[1] + _ref_lat)), (ll[1] - _ref_lat) * r)


## MoonComms positions are (east, up, -north) in metres in the base's tangent frame.
func _comms_pos(gp: Vector3) -> Vector3:
	var e := _enu(_lonlat_rad(gp))
	return Vector3(e.x, 0.0, -e.y)


func _find_env(n: Node) -> LunarEnvironment:
	if n is LunarEnvironment:
		return n as LunarEnvironment
	for c in n.get_children():
		var r := _find_env(c)
		if r != null:
			return r
	return null


# ================================================================= debug

func _unhandled_input(event: InputEvent) -> void:
	if not active or _env == null or not OS.is_debug_build() or Inventory.ui_open:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == DEBUG_SUN_KEY:
		var s := _env.get_sun_direction()
		_env.subsolar_longitude_deg = wrapf(rad_to_deg(atan2(s.x, s.z)) - DEBUG_SUN_STEP_DEG, -180.0, 180.0)
		Dialogue.say("Debug: the Sun moved %d degrees west." % int(DEBUG_SUN_STEP_DEG), 2.0, "Debug")
		get_viewport().set_input_as_handled()


# ================================================================= HUD

func _build_hud() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 4                                      # under the inventory (10) and the dialogue (20)
	add_child(_layer)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -300.0
	_panel.offset_right = -16.0
	_panel.offset_top = 16.0
	_panel.offset_bottom = 16.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.07, 0.72)
	sb.border_color = Color(0.55, 0.65, 0.8, 0.45)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10.0)
	_panel.add_theme_stylebox_override("panel", sb)
	_layer.add_child(_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.custom_minimum_size = Vector2(264.0, 0.0)
	box.add_theme_constant_override("separation", 3)
	_panel.add_child(box)

	_comms_label = _label("COMMS", 15, COL_TEXT)
	box.add_child(_comms_label)
	_comms_note = _label("", 12, COL_DIM)
	_comms_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_comms_note)

	_suit_label = _label("SUIT", 15, COL_TEXT)
	box.add_child(_suit_label)
	_reserve_label = _label("THERMAL RESERVE", 12, COL_DIM)
	box.add_child(_reserve_label)
	var bg := ColorRect.new()
	bg.color = Color(1, 1, 1, 0.13)
	bg.custom_minimum_size = Vector2(0, 11)
	bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)
	_reserve_fill = ColorRect.new()
	_reserve_fill.color = COL_RESERVE
	_reserve_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reserve_fill.anchor_top = 0.0
	_reserve_fill.anchor_bottom = 1.0
	_reserve_fill.anchor_left = 0.0
	_reserve_fill.anchor_right = 1.0
	bg.add_child(_reserve_fill)
	_suit_note = _label("", 12, COL_DIM)
	_suit_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_suit_note)


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _update_hud() -> void:
	# --- communications
	_comms_label.visible = _have_comms
	_comms_note.visible = _have_comms
	if _have_comms and comms != null:
		var snr := comms.best_snr_db(PLAYER)
		var col := COL_TEXT
		if quality < 0.3:
			col = COL_CRIT
		elif quality < 0.6:
			col = COL_WARN
		if snr > -1000.0:
			var bars := clampi(int(round(quality * 4.0)), 0, 4)
			_comms_label.text = "COMMS  [%s%s]  %d%%" % ["|".repeat(bars), ".".repeat(4 - bars), int(round(quality * 100.0))]
			_comms_note.text = _route_text()
		else:
			_comms_label.text = "COMMS  NO LINK"
			_comms_note.text = "out of range: Mission Control is unreadable"
		_comms_label.add_theme_color_override("font_color", col)

	# --- suit
	var tc := _suit_k - 273.15
	var gc := 0.0
	if thermal != null:
		gc = thermal.surface_temp_k(PLAYER) - 273.15
	_suit_label.text = "SUIT  %d °C     ground %d °C" % [int(round(tc)), int(round(gc))]
	var rcol := COL_RESERVE
	if reserve <= 0.15:
		rcol = COL_CRIT
	elif reserve <= 0.4:
		rcol = COL_WARN
	_reserve_fill.color = rcol
	_reserve_fill.anchor_right = clampf(reserve, 0.0, 1.0)
	_reserve_label.text = "THERMAL RESERVE  %d%%" % int(round(reserve * 100.0))
	var notes: Array[String] = []
	if _sheltered:
		notes.append("in the base: recovering")
	elif _kind > 0:
		notes.append("overheating: find shade or the base")
	elif _kind < 0:
		notes.append("too cold: get to the base")
	if not Repairs.is_done("suit_electrical"):
		notes.append("suit power fault: weak thermal control")
	_suit_note.text = ", ".join(notes)
	_suit_note.visible = not notes.is_empty()
	_panel.modulate.a = 0.6 + 0.4 * absf(sin(Time.get_ticks_msec() / 1000.0 * 5.0)) if reserve <= 0.15 else 1.0


func _route_text() -> String:
	var path := comms.signal_path(PLAYER)
	var names: Array[String] = []
	for i in range(1, path.size()):
		names.append(str(NODE_NAMES.get(path[i], path[i])))
	var text := "via " + " > ".join(names)
	var route := comms.get_route(PLAYER)
	if bool(route["connected"]):
		text += "    delay %.1f s" % float(route["latency_s"])
	if quality < 0.97:
		text += "\nsignal weak: speech is breaking up"
	return text
