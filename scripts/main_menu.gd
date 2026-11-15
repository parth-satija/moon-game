extends Control
## Main menu: Continue (the most recently saved slot), New Game, Load Game, Quit.
## New Game and Load Game open a list of save slots. The slots themselves are handled by the GameState autoload,
## which keeps the chosen slot saved continuously while it is played.

enum Mode { NEW, LOAD }

const BG := Color(0.01, 0.01, 0.02, 1.0)
const PANEL_BG := Color(0.04, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.55, 0.65, 0.8, 0.7)
const TEXT := Color(0.93, 0.95, 1.0)
const TEXT_DIM := Color(0.62, 0.68, 0.78)
const ACCENT := Color(1.0, 0.75, 0.35)
const WARN := Color(0.95, 0.5, 0.4)

var _main_box: VBoxContainer
var _slots_box: VBoxContainer
var _slots_title: Label
var _slot_list: VBoxContainer
var _continue_button: Button
var _continue_info: Label
var _load_button: Button

var _mode := Mode.LOAD
var _armed := ""            # "overwrite:2" / "delete:2": the button that has been pressed once and waits for a second press
var _busy := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	_build_ui()
	_refresh_main()
	_show_main()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE and _slots_box.visible:
		_show_main()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- actions

func _on_continue() -> void:
	if _busy:
		return
	_busy = true
	if not GameState.continue_latest():
		_busy = false
		_refresh_main()


func _on_new_game() -> void:
	_open_slots(Mode.NEW)


func _on_load_game() -> void:
	_open_slots(Mode.LOAD)


func _on_slot_action(slot: int) -> void:
	if _busy:
		return
	if _mode == Mode.NEW:
		if GameState.slot_exists(slot) and _armed != "overwrite:%d" % slot:
			_armed = "overwrite:%d" % slot
			_rebuild_slots()
			return
		_busy = true
		GameState.start_new_game(slot)
	else:
		_busy = true
		if not GameState.continue_game(slot):
			_busy = false
			_rebuild_slots()


func _on_slot_delete(slot: int) -> void:
	if _armed != "delete:%d" % slot:
		_armed = "delete:%d" % slot
		_rebuild_slots()
		return
	GameState.delete_slot(slot)
	_armed = ""
	_rebuild_slots()
	_refresh_main()


func _show_main() -> void:
	_armed = ""
	_slots_box.visible = false
	_main_box.visible = true
	_refresh_main()


func _open_slots(mode: Mode) -> void:
	_mode = mode
	_armed = ""
	_slots_title.text = "New game: choose a slot" if mode == Mode.NEW else "Load game"
	_main_box.visible = false
	_slots_box.visible = true
	_rebuild_slots()


# ---------------------------------------------------------------- content

func _refresh_main() -> void:
	var latest := GameState.latest_slot()
	_continue_button.disabled = latest == 0
	_load_button.disabled = latest == 0
	if latest == 0:
		_continue_info.text = "No saved game yet"
	else:
		var s := GameState.slot_summary(latest)
		_continue_info.text = "Slot %d  |  %s  |  %s" % [latest, _stage_text(s), _playtime_text(float(s["playtime_s"]))]


func _rebuild_slots() -> void:
	for c in _slot_list.get_children():
		_slot_list.remove_child(c)
		c.queue_free()
	for slot in range(1, GameState.SLOT_COUNT + 1):
		_slot_list.add_child(_make_slot_row(slot))


func _make_slot_row(slot: int) -> Control:
	var s := GameState.slot_summary(slot)
	var exists: bool = s["exists"]

	var row := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16, 0.95)
	sb.border_color = Color(0.3, 0.34, 0.42, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12.0)
	row.add_theme_stylebox_override("panel", sb)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	row.add_child(h)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(info)
	info.add_child(_label("Slot %d" % slot, 20, TEXT if exists else TEXT_DIM))
	if exists:
		info.add_child(_label("%s  |  %s" % [_stage_text(s), _playtime_text(float(s["playtime_s"]))], 15, TEXT_DIM))
		info.add_child(_label("Saved " + _date_text(float(s["saved"])), 14, TEXT_DIM))
	else:
		info.add_child(_label("Empty", 15, TEXT_DIM))

	var action := Button.new()
	action.custom_minimum_size = Vector2(150, 44)
	action.focus_mode = Control.FOCUS_NONE
	if _mode == Mode.NEW:
		if exists:
			var armed := _armed == "overwrite:%d" % slot
			action.text = "Really overwrite?" if armed else "Overwrite"
			if armed:
				action.add_theme_color_override("font_color", WARN)
		else:
			action.text = "Start"
	else:
		action.text = "Load"
		action.disabled = not exists
	action.pressed.connect(_on_slot_action.bind(slot))
	h.add_child(action)

	if exists:
		var del := Button.new()
		del.custom_minimum_size = Vector2(110, 44)
		del.focus_mode = Control.FOCUS_NONE
		var del_armed := _armed == "delete:%d" % slot
		del.text = "Sure?" if del_armed else "Delete"
		if del_armed:
			del.add_theme_color_override("font_color", WARN)
		del.pressed.connect(_on_slot_delete.bind(slot))
		h.add_child(del)
	return row


func _stage_text(s: Dictionary) -> String:
	var site := ""
	if bool(s["has_site"]):
		site = "%.2f° %s, %.2f° %s" % [absf(float(s["lon_deg"])), "E" if float(s["lon_deg"]) >= 0.0 else "W",
			absf(float(s["lat_deg"])), "N" if float(s["lat_deg"]) >= 0.0 else "S"]
	match str(s["stage"]):
		"playing":
			return "On the surface, landing site %s" % site
		"landing":
			return "Landing at %s" % site
		_:
			return "Choosing a landing site"


func _playtime_text(seconds: float) -> String:
	var t := int(seconds)
	return "Played %d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]


func _date_text(unix: float) -> String:
	var local := int(unix) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(local, true)


# ---------------------------------------------------------------- layout

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 28)
	center.add_child(column)

	var title := _label("Schrodinger's Astronaut", 64, ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	# --- main buttons
	_main_box = VBoxContainer.new()
	_main_box.custom_minimum_size = Vector2(420, 0)
	_main_box.add_theme_constant_override("separation", 12)
	column.add_child(_main_box)

	_continue_button = _button("Continue", _on_continue)
	_main_box.add_child(_continue_button)
	_continue_info = _label("", 14, TEXT_DIM)
	_continue_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main_box.add_child(_continue_info)
	_main_box.add_child(_button("New Game", _on_new_game))
	_load_button = _button("Load Game", _on_load_game)
	_main_box.add_child(_load_button)
	_main_box.add_child(_button("Orbital Docking Sim", func() -> void: get_tree().change_scene_to_file("res://scenes/orbital_docking.tscn")))
	_main_box.add_child(_button("Quit", func() -> void: GameState.quit_game()))

	# --- slot list
	_slots_box = VBoxContainer.new()
	_slots_box.custom_minimum_size = Vector2(760, 0)
	_slots_box.add_theme_constant_override("separation", 14)
	column.add_child(_slots_box)

	_slots_title = _label("", 26, TEXT)
	_slots_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slots_box.add_child(_slots_title)
	_slot_list = VBoxContainer.new()
	_slot_list.add_theme_constant_override("separation", 10)
	_slots_box.add_child(_slot_list)
	_slots_box.add_child(_button("Back", _show_main))


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.add_theme_font_size_override("font_size", 24)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(handler)
	return b


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
