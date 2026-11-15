extends Node
## Autoload "Life": the suit's oxygen, the propellant chain, the HUD that shows them, and the ending.
## Everything here is saved in the active slot by GameState (get_state / set_state / reset).
##
## OXYGEN
##   The suit tank drains all the time (more when you run, a little less in the buggy). Inside the base it
##   refills, and so does standing next to the powered spacecraft. Stations are nodes in the group
##   "oxygen_station" with a method oxygen_rate_at(world_pos) -> fraction of a full tank per second.
##   The three suit repairs matter:
##       Suit Oxygen Filter       without it the tank only fills to 50%
##       Oxygen Supply Connection without it the line leaks: the tank drains 35% faster
##       Suit Electrical System   without it the readout is scrambled (the percentage is hidden)
##   At zero the player blacks out and wakes up inside the base (the buggy stays where it was).
##
## FUEL
##   The propellant plant in the base (fuel_plant.gd) makes fuel once the base AND the solar array are repaired.
##   Fuel is hauled to the spacecraft in the buggy (BUGGY_CARGO per trip, needs the chassis repaired) and
##   transferred at the spacecraft (return_rocket.gd). The spacecraft launches with a full tank.
##
## ENDING
##   The launch is the orbital docking sequence (orbital_docking.gd): the spacecraft hands over to it. Its successful
##   dock calls complete_mission(), which sets the Repairs flag "mission_complete" (the pad is then empty).
##
##     Life.oxygen   Life.rocket_fuel   Life.buggy_cargo   Life.plant_fuel   Life.blackouts
##     Life.objective_text()            Life.load_buggy(pos)                 Life.unload_to_rocket(pos)

signal fuel_changed
signal blacked_out

const FLAG_MISSION_COMPLETE := "mission_complete"

# --- oxygen
const TANK_SECONDS := 3600.0               # a full tank lasts this long standing still with a healthy suit
const LEAK_EXTRA := 0.35                   # extra drain while the oxygen connection is unrepaired
const POWER_FAULT_EXTRA := 0.15            # extra drain while the suit electrics are unrepaired
const BUGGY_FACTOR := 0.8                  # drain while seated in the buggy
const WALK_EXTRA := 0.5                    # extra drain at running speed
const RUN_SPEED := 4.2
const LOW := 0.25
const CRITICAL := 0.10
const WAKE_OXYGEN := 0.4

# --- fuel
const PLANT_CAPACITY := 100.0
const PLANT_SECONDS := 420.0               # the plant makes a full 100 in this long while powered
const BUGGY_CARGO := 50.0
const ROCKET_TANK := 100.0
const LOAD_RANGE_M := 45.0                 # buggy to plant
const UNLOAD_RANGE_M := 30.0               # buggy to spacecraft

const O2_COLOR := Color(0.35, 0.8, 1.0)
const WARN_COLOR := Color(1.0, 0.7, 0.25)
const CRIT_COLOR := Color(1.0, 0.3, 0.28)
const FUEL_COLOR := Color(1.0, 0.62, 0.2)
const TEXT := Color(0.93, 0.95, 1.0)
const DIM := Color(0.62, 0.68, 0.78)

var oxygen := 0.5                          # fraction of a FULL tank
var plant_fuel := 0.0
var buggy_cargo := 0.0
var rocket_fuel := 0.0
var blackouts := 0

## Set while a cutscene runs: oxygen stops draining and the HUD can be hidden.
var suspended := false
var hud_hidden := false

var _warned_low := false
var _warned_crit := false
var _intro_shown := false
var _session_t := 0.0
var _last_refill := 0.0
var _blacking_out := false
var _pulse := 0.0

var _layer: CanvasLayer
var _panel: PanelContainer
var _o2_label: Label
var _o2_fill: ColorRect
var _o2_cap: ColorRect
var _o2_note: Label
var _fuel_label: Label
var _fuel_fill: ColorRect
var _fuel_note: Label


func _ready() -> void:
	_build_hud()


# ================================================================= oxygen

func max_oxygen() -> float:
	return 1.0 if Repairs.is_done("suit_oxygen_filter") else 0.5


func drain_multiplier(p: MoonPlayer) -> float:
	var m := 1.0
	if not Repairs.is_done("suit_oxygen_connection"):
		m += LEAK_EXTRA
	if not Repairs.is_done("suit_electrical"):
		m += POWER_FAULT_EXTRA
	if p.vehicle != null:
		return m * BUGGY_FACTOR
	var v := p.get_real_velocity()
	var h := (v - p.up_direction * v.dot(p.up_direction)).length()
	return m * (1.0 + WALK_EXTRA * clampf(h / RUN_SPEED, 0.0, 1.0))


func _refill_rate(p: MoonPlayer) -> float:
	var r := 0.0
	for n in get_tree().get_nodes_in_group("oxygen_station"):
		if n.has_method("oxygen_rate_at"):
			r = maxf(r, float(n.call("oxygen_rate_at", p.global_position)))
	return r


func _physics_process(delta: float) -> void:
	if suspended or not GameState.in_game:
		return
	var p := _player()
	if p == null:
		return
	_session_t += delta
	_tick_plant(delta)
	_show_intro()

	_last_refill = _refill_rate(p)
	if _last_refill > 0.0:
		oxygen = maxf(oxygen, minf(max_oxygen(), oxygen + _last_refill * delta))
		if oxygen > LOW + 0.05:
			_warned_low = false
		if oxygen > CRITICAL + 0.05:
			_warned_crit = false
		return

	oxygen = maxf(0.0, oxygen - drain_multiplier(p) / TANK_SECONDS * delta)
	if oxygen > LOW + 0.05:
		_warned_low = false
	if oxygen > CRITICAL + 0.05:
		_warned_crit = false
	if oxygen <= CRITICAL and not _warned_crit:
		_warned_crit = true
		_warned_low = true
		Dialogue.say("Oxygen critical! Get to the base now.", 4.0, "Suit computer", true)
	elif oxygen <= LOW and not _warned_low:
		_warned_low = true
		Dialogue.say("Oxygen low. Head back to the base to refill.", 4.0, "Suit computer")
	if oxygen <= 0.0:
		_blackout(p)


func _show_intro() -> void:
	if _intro_shown or _session_t < 14.0:
		return
	_intro_shown = true
	if not Repairs.is_done("suit_oxygen_filter"):
		Dialogue.say("Your oxygen filter is worn out, so the tank only holds half a charge, and the line is leaking. The base refills it.", 7.0, "Suit computer")


func _blackout(p: MoonPlayer) -> void:
	if _blacking_out:
		return
	_blacking_out = true
	suspended = true
	blackouts += 1
	blacked_out.emit()
	Dialogue.say("Oxygen exhausted. Everything goes dark...", 3.0, "Suit computer", true)

	var layer := CanvasLayer.new()
	layer.layer = 60
	var rect := ColorRect.new()
	rect.color = Color(0, 0, 0, 0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	add_child(layer)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 1.0, 1.4)
	tw.tween_callback(_wake.bind(p))
	tw.tween_interval(1.2)
	tw.tween_property(rect, "color:a", 0.0, 1.0)
	tw.tween_callback(func() -> void:
		layer.queue_free()
		suspended = false
		_blacking_out = false)


# Mission control's recovery team carries the player to the base. The buggy stays where it was.
func _wake(p: MoonPlayer) -> void:
	if not is_instance_valid(p):
		return
	if p.vehicle != null and is_instance_valid(p.vehicle):
		p.vehicle.call("dismount")
	var base: Node = null
	if MoonPlanet.instance != null:
		base = MoonPlanet.instance.get_node_or_null("InteriorBase")
	oxygen = minf(WAKE_OXYGEN, max_oxygen())
	_warned_low = false
	_warned_crit = false
	if base != null and base.has_method("enter_instantly"):
		base.call("enter_instantly", p)
		Dialogue.say("You come round on the base floor. Recovery drones dragged you in. Your tank is refilling.", 6.0, "Mission Control")
	else:
		Dialogue.say("You come round with the suit on reserve. Find the base.", 6.0, "Mission Control")


# ================================================================= fuel

func plant_powered() -> bool:
	return Repairs.stage_complete("base") and Repairs.stage_complete("solar")


func cargo_capacity() -> float:
	return BUGGY_CARGO if Repairs.is_done("buggy_chassis") else 0.0


func find_buggy() -> Node3D:
	return get_tree().get_first_node_in_group("lrv") as Node3D


func _tick_plant(delta: float) -> void:
	if plant_powered() and plant_fuel < PLANT_CAPACITY:
		plant_fuel = minf(PLANT_CAPACITY, plant_fuel + PLANT_CAPACITY / PLANT_SECONDS * delta)


## Plant -> buggy. Returns what to tell the player.
func load_buggy(from_pos: Vector3) -> String:
	if not plant_powered():
		return "The plant has no power. Finish the base and solar repairs."
	var buggy := find_buggy()
	if buggy == null:
		return "There is no buggy to load."
	if buggy.global_position.distance_to(from_pos) > LOAD_RANGE_M:
		return "Park the buggy within %d m of the base to load its tank." % int(LOAD_RANGE_M)
	var cap := cargo_capacity()
	if cap <= 0.0:
		return "The buggy's frame cannot carry a tank. Repair its chassis first."
	if buggy_cargo >= cap - 0.01:
		return "The buggy's tank is full (%d). Take it to the spacecraft." % int(round(buggy_cargo))
	if plant_fuel < 1.0:
		return "The plant has not made any fuel yet. It makes a full %d in about %d minutes." % [int(PLANT_CAPACITY), int(PLANT_SECONDS / 60.0)]
	var amount := minf(plant_fuel, cap - buggy_cargo)
	plant_fuel -= amount
	buggy_cargo += amount
	fuel_changed.emit()
	return "Loaded %d fuel into the buggy (%d / %d). Drive it to the spacecraft." % [int(round(amount)), int(round(buggy_cargo)), int(cap)]


## Buggy -> spacecraft. Returns what to tell the player.
func unload_to_rocket(rocket_pos: Vector3) -> String:
	var buggy := find_buggy()
	if buggy == null or buggy.global_position.distance_to(rocket_pos) > UNLOAD_RANGE_M:
		return "Bring the buggy within %d m of the spacecraft to transfer fuel." % int(UNLOAD_RANGE_M)
	if buggy_cargo < 1.0:
		return "The buggy's tank is empty. Load fuel at the propellant plant in the base."
	if rocket_fuel >= ROCKET_TANK - 0.01:
		return "The spacecraft's tank is already full."
	var amount := minf(buggy_cargo, ROCKET_TANK - rocket_fuel)
	buggy_cargo -= amount
	rocket_fuel += amount
	fuel_changed.emit()
	if rocket_fuel >= ROCKET_TANK - 0.01:
		return "Fuel transferred. The spacecraft's tank is full. It is ready to launch."
	return "Transferred %d fuel. The spacecraft's tank is at %d%%. Another trip is needed." % [int(round(amount)), int(round(rocket_fuel / ROCKET_TANK * 100.0))]


## What the HUD objective line says once every repair is done.
func objective_text() -> String:
	if Repairs.has_flag(FLAG_MISSION_COMPLETE):
		return "Mission complete"
	if rocket_fuel >= ROCKET_TANK - 0.01:
		return "Fly home: board the spacecraft and launch (E)"
	return "Fuel the spacecraft (%d%%): load fuel at the base's propellant plant, haul it in the buggy" % int(round(rocket_fuel / ROCKET_TANK * 100.0))


# ================================================================= ending

func complete_mission() -> void:
	Repairs.set_flag(FLAG_MISSION_COMPLETE)


# ================================================================= saving

func get_state() -> Dictionary:
	return {"oxygen": oxygen, "plant": plant_fuel, "cargo": buggy_cargo, "tank": rocket_fuel,
		"blackouts": blackouts, "intro": _intro_shown}


func set_state(s: Dictionary) -> void:
	reset()
	if s.is_empty():
		return
	oxygen = clampf(float(s.get("oxygen", oxygen)), 0.0, 1.0)
	plant_fuel = clampf(float(s.get("plant", 0.0)), 0.0, PLANT_CAPACITY)
	buggy_cargo = clampf(float(s.get("cargo", 0.0)), 0.0, BUGGY_CARGO)
	rocket_fuel = clampf(float(s.get("tank", 0.0)), 0.0, ROCKET_TANK)
	blackouts = int(s.get("blackouts", 0))
	_intro_shown = bool(s.get("intro", false))
	fuel_changed.emit()


## Back to the start of a game.
func reset() -> void:
	oxygen = 0.5
	plant_fuel = 0.0
	buggy_cargo = 0.0
	rocket_fuel = 0.0
	blackouts = 0
	suspended = false
	hud_hidden = false
	_warned_low = false
	_warned_crit = false
	_intro_shown = false
	_session_t = 0.0
	_blacking_out = false


# ================================================================= HUD

func set_hud_visible(on: bool) -> void:
	hud_hidden = not on


func _player() -> MoonPlayer:
	return get_tree().get_first_node_in_group("player") as MoonPlayer


func _build_hud() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 4                                      # under the inventory (10) and the dialogue (20)
	add_child(_layer)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = 16.0
	_panel.offset_right = 286.0
	_panel.offset_top = -16.0
	_panel.offset_bottom = -16.0
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN      # grows upward from the bottom edge
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
	box.add_theme_constant_override("separation", 3)
	_panel.add_child(box)

	_o2_label = _label("OXYGEN", 15, TEXT)
	box.add_child(_o2_label)
	var o2_bg := _bar_bg(box)
	_o2_fill = _bar_fill(o2_bg, O2_COLOR)
	_o2_cap = ColorRect.new()                               # marks the tank limit while the filter is worn
	_o2_cap.color = Color(1, 1, 1, 0.85)
	_o2_cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_o2_cap.anchor_top = 0.0
	_o2_cap.anchor_bottom = 1.0
	_o2_cap.offset_left = -1.0
	_o2_cap.offset_right = 1.0
	o2_bg.add_child(_o2_cap)
	_o2_note = _label("", 12, DIM)
	box.add_child(_o2_note)

	_fuel_label = _label("FUEL", 15, TEXT)
	box.add_child(_fuel_label)
	_fuel_fill = _bar_fill(_bar_bg(box), FUEL_COLOR)
	_fuel_note = _label("", 12, DIM)
	box.add_child(_fuel_note)


func _label(text: String, size: int, color: Color, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _bar_bg(parent: Control) -> ColorRect:
	var bg := ColorRect.new()
	bg.color = Color(1, 1, 1, 0.13)
	bg.custom_minimum_size = Vector2(0, 13)
	bg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bg)
	return bg


func _bar_fill(bg: ColorRect, color: Color) -> ColorRect:
	var fill := ColorRect.new()
	fill.color = color
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fill.anchor_top = 0.0
	fill.anchor_bottom = 1.0
	fill.anchor_left = 0.0
	fill.anchor_right = 0.0
	bg.add_child(fill)
	return fill


func _process(delta: float) -> void:
	_pulse += delta
	var show := GameState.in_game and not hud_hidden
	_layer.visible = show
	if not show:
		return

	var cap := max_oxygen()
	var color := O2_COLOR
	if oxygen <= CRITICAL:
		color = CRIT_COLOR
	elif oxygen <= LOW:
		color = WARN_COLOR
	_o2_fill.color = color
	_o2_fill.anchor_right = clampf(oxygen, 0.0, 1.0)
	_o2_cap.visible = cap < 1.0
	_o2_cap.anchor_left = cap
	_o2_cap.anchor_right = cap
	var pct := str(int(round(oxygen * 100.0))) if Repairs.is_done("suit_electrical") else "--"
	_o2_label.text = "OXYGEN  %s%%%s" % [pct, "   refilling" if _last_refill > 0.0 else ""]
	_o2_label.add_theme_color_override("font_color", color if oxygen <= LOW else TEXT)
	var notes: Array[String] = []
	if cap < 1.0:
		notes.append("tank limit 50%: filter worn")
	if not Repairs.is_done("suit_oxygen_connection"):
		notes.append("line leaking")
	if not Repairs.is_done("suit_electrical"):
		notes.append("suit power fault")
	_o2_note.text = ", ".join(notes)
	_o2_note.visible = not notes.is_empty()

	_fuel_fill.anchor_right = clampf(rocket_fuel / ROCKET_TANK, 0.0, 1.0)
	_fuel_label.text = "FUEL  spacecraft tank %d%%" % int(round(rocket_fuel / ROCKET_TANK * 100.0))
	var plant_text := "plant %d/%d" % [int(round(plant_fuel)), int(PLANT_CAPACITY)] if plant_powered() else "plant offline"
	_fuel_note.text = "buggy %d/%d   %s" % [int(round(buggy_cargo)), int(BUGGY_CARGO), plant_text]

	_panel.modulate.a = 0.6 + 0.4 * absf(sin(_pulse * 5.0)) if oxygen <= CRITICAL else 1.0
