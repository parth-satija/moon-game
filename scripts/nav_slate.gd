extends CanvasLayer
## Autoload "NavSlate": the nav slate. N opens / closes it, Esc closes it.
##
## Pages: MISSION CONTROL (the points mission control knows, absolute or relative to the crash site / base),
## NAV COMPUTER (dead-reckoning position, uncertainty, fixes) and PLOTTER (range and bearing between two
## coordinates). Like the inventory it frees the mouse and stops the player (Inventory.ui_open).

const PANEL_BG := Color(0.04, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.55, 0.65, 0.8, 0.7)
const TEXT := Color(0.93, 0.95, 1.0)
const TEXT_DIM := Color(0.62, 0.68, 0.78)
const ACCENT := Color(1.0, 0.75, 0.35)
const GOOD := Color(0.55, 0.9, 0.55)

const PAGE_NAMES := ["MISSION CONTROL", "NAV COMPUTER", "PLOTTER"]
const REL_NAMES := ["ABSOLUTE", "RELATIVE TO CRASH SITE", "RELATIVE TO BASE"]

var _root: Control
var _page := 0
var _rel_mode := 0
var _refresh_cd := 0.0
var _pages: Array[Control] = []
var _page_buttons: Array[Button] = []
var _mc_text: Label
var _nav_text: Label
var _mode_button: Button
var _status: Label
var _assist: CheckButton
var _opts_row: Control
var _from_opt: OptionButton
var _to_opt: OptionButton
var _opt_ids: Array[String] = []
var _fields: Dictionary = {}                      # "from_lat", "from_lon", "to_lat", "to_lon" -> LineEdit
var _plot_result: Label
var _mono: SystemFont


func _ready() -> void:
	layer = 11
	process_mode = Node.PROCESS_MODE_ALWAYS
	_mono = SystemFont.new()
	_mono.font_names = PackedStringArray(["Consolas", "Courier New", "monospace"])
	_build_ui()
	_root.visible = false
	LunarNav.event_logged.connect(_on_event)
	LunarNav.mc_changed.connect(_fill_options)


func _exit_tree() -> void:
	if Inventory != null and is_open():
		Inventory.ui_open = false


func is_open() -> bool:
	return _root != null and _root.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	if is_open() or Inventory.ui_open or get_tree().paused:
		return
	if not (LunarNav.active and GameState.in_game):
		return
	_root.visible = true
	Inventory.ui_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_set_status("")
	_fill_options()
	_show_page(_page)
	_refresh()


func close() -> void:
	if not is_open():
		return
	var f := get_viewport().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	_root.visible = false
	Inventory.ui_open = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_N:
		if is_open() or (LunarNav.active and not Inventory.ui_open):
			toggle()
			get_viewport().set_input_as_handled()
	elif is_open():
		if event.keycode == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_I or event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()          # the inventory must not open on top of the slate


func _process(delta: float) -> void:
	if not is_open():
		return
	if not (LunarNav.active and GameState.in_game):
		close()
		return
	_refresh_cd -= delta
	if _refresh_cd <= 0.0:
		_refresh_cd = 0.25
		_refresh()


func _on_event(text: String) -> void:
	_set_status(text)


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ================================================================= content

func _refresh() -> void:
	match _page:
		0:
			_mc_text.text = _build_mc_text()
		1:
			_nav_text.text = _build_nav_text()


func _fmt_lat(v: float) -> String:
	return ("%+.5f" % v).lpad(11)


func _fmt_age(sec: float) -> String:
	if sec < 90.0:
		return "%d s" % int(sec)
	return "%d min" % int(round(sec / 60.0))


func _build_mc_text() -> String:
	var rows := LunarNav.point_rows()
	var ref: Dictionary = {}
	if _rel_mode == 1:
		ref = LunarNav.point_row("crash")
	elif _rel_mode == 2:
		ref = LunarNav.point_row("base")
	var lines: Array[String] = []
	lines.append("Mission control cannot track you. These are the only positions they have.")
	lines.append("Coordinates in decimal degrees: latitude N+ / S-, longitude E+ / W-.")
	lines.append("")
	if _rel_mode == 0:
		lines.append("%s %s %s" % ["POINT".rpad(34), "LATITUDE".lpad(11), "LONGITUDE".lpad(12)])
	else:
		lines.append("%s %s %s     (point minus reference)" % ["POINT".rpad(34), "D-LAT".lpad(11), "D-LON".lpad(12)])
	var ref_ok := not ref.is_empty() and bool(ref["known"])
	for r in rows:
		var name := str(r["name"])
		if not bool(r["known"]):
			lines.append("%s %s" % [name.rpad(34), str(r["note"])])
			continue
		var lat := float(r["lat_deg"])
		var lon := float(r["lon_deg"])
		if _rel_mode != 0:
			if not ref_ok:
				lines.append("%s reference unavailable" % name.rpad(34))
				continue
			lat -= float(ref["lat_deg"])
			lon -= float(ref["lon_deg"])
		var tail := ""
		if float(r["dispersion_m"]) > 0.0:
			tail = "   object within ~%d m of this point" % int(r["dispersion_m"])
		if str(r["note"]) != "":
			tail += "   [%s]" % str(r["note"])
		lines.append("%s %s %s%s" % [name.rpad(34), _fmt_lat(lat), _fmt_lat(lon).lpad(12), tail])
	lines.append("")
	var mpd := LunarNav.meters_per_degree()
	var crash := LunarNav.point_row("crash")
	var cos_text := "n/a"
	if not crash.is_empty() and bool(crash["known"]):
		cos_text = "%.4f" % cos(deg_to_rad(float(crash["lat_deg"])))
	lines.append("GROUND SCALE")
	lines.append("  1 degree of latitude  = %.2f km" % (mpd / 1000.0))
	lines.append("  1 degree of longitude = %.2f km x cos(latitude)     cos(latitude) at the crash site = %s" % [mpd / 1000.0, cos_text])
	lines.append("  0.01 deg = %d m     0.001 deg = %.1f m     0.0001 deg = %.1f m" % [int(round(mpd * 0.01)), mpd * 0.001, mpd * 0.0001])
	lines.append("  Bearing: 000 = north, 090 = east.   Walk the offsets north / east from where you KNOW you are.")
	return "\n".join(lines)


func _build_nav_text() -> String:
	var lines: Array[String] = []
	lines.append("DEAD-RECKONING COMPUTER")
	lines.append("  Position    lat %s   lon %s     +/- %s (1 sigma)" % [
		_fmt_lat(LunarNav.est_lat_deg()), _fmt_lat(LunarNav.est_lon_deg()), LunarNav.fmt_dist(LunarNav.pos_sigma_m())])
	lines.append("  Last fix    %s, %s ago" % [LunarNav.fix_label(), _fmt_age(LunarNav.fix_age_s())])
	lines.append("  Run since   %s     N %s   E %s  (as measured)" % [
		LunarNav.fmt_dist(LunarNav.since_fix_m()),
		("%+.0f m" % LunarNav.trip_north_m()), ("%+.0f m" % LunarNav.trip_east_m())])
	lines.append("  Gyro        last sighted %s ago, heading good to +/- %.1f deg" % [
		_fmt_age(LunarNav.sight_age_s()), LunarNav.hdg_sigma_deg()])
	lines.append("  The uncertainty is the computer's own estimate. Odometer scale and gyro drift are not known to it.")
	lines.append("")
	lines.append("CELESTIAL REFERENCES (published ephemeris, evaluated at the DR position)")
	var sky := LunarNav.sky_prediction()
	if sky.is_empty():
		lines.append("  no ephemeris available")
	else:
		for k in ["sun", "earth"]:
			var s: Dictionary = sky[k]
			lines.append("  %s  sub-point lat %s lon %s     az %03d  el %+.1f deg%s" % [
				str(k).capitalize().rpad(5), _fmt_lat(float(s["lat"])), _fmt_lat(float(s["lon"])),
				int(round(float(s["az"]))) % 360, float(s["el"]),
				"   (below horizon)" if float(s["el"]) < 3.0 else ""])
	lines.append("")
	lines.append("PROCEDURES")
	lines.append("  Touch fix   walk up to the crash site / base and press its button below")
	lines.append("  [G]         centre the Sun (or Earth) in the crosshair: re-aligns the gyro")
	lines.append("  [R]         aim at the crash site or the base: laser range + gyro bearing = position fix")
	lines.append("  Both need the slate closed. Pitfalls: Sun near the zenith, a sloppy aim, or a bad gyro spoil a fix.")
	return "\n".join(lines)


# ================================================================= plotter

func _fill_options() -> void:
	if _from_opt == null:
		return
	var from_sel := _opt_ids[_from_opt.selected] if (_from_opt.selected >= 0 and _from_opt.selected < _opt_ids.size()) else ""
	var to_sel := _opt_ids[_to_opt.selected] if (_to_opt.selected >= 0 and _to_opt.selected < _opt_ids.size()) else ""
	_opt_ids.clear()
	_from_opt.clear()
	_to_opt.clear()
	_opt_ids.append("dr")
	_from_opt.add_item("DR position")
	_to_opt.add_item("DR position")
	for r in LunarNav.point_rows():
		if bool(r["known"]):
			_opt_ids.append(str(r["id"]))
			_from_opt.add_item(str(r["name"]))
			_to_opt.add_item(str(r["name"]))
	_from_opt.selected = maxi(_opt_ids.find(from_sel), 0)
	_to_opt.selected = clampi(maxi(_opt_ids.find(to_sel), 0) if to_sel != "" else 1, 0, _opt_ids.size() - 1)


func _coords_of(id: String) -> Array:
	if id == "dr":
		return [LunarNav.est_lat_deg(), LunarNav.est_lon_deg()]
	var r := LunarNav.point_row(id)
	if r.is_empty() or not bool(r["known"]):
		return []
	return [float(r["lat_deg"]), float(r["lon_deg"])]


func _on_option_selected(_index: int, is_from: bool) -> void:
	if not _assist.button_pressed:
		return
	var opt := _from_opt if is_from else _to_opt
	if opt.selected < 0 or opt.selected >= _opt_ids.size():
		return
	var c := _coords_of(_opt_ids[opt.selected])
	if c.is_empty():
		return
	var pre := "from" if is_from else "to"
	(_fields[pre + "_lat"] as LineEdit).text = "%.5f" % float(c[0])
	(_fields[pre + "_lon"] as LineEdit).text = "%.5f" % float(c[1])


func _on_assist_toggled(on: bool) -> void:
	_opts_row.visible = on
	if on:
		_on_option_selected(0, true)
		_on_option_selected(0, false)


func _on_compute() -> void:
	var v: Array[float] = []
	for key in ["from_lat", "from_lon", "to_lat", "to_lon"]:
		var t := (_fields[key] as LineEdit).text.strip_edges()
		if not t.is_valid_float():
			_plot_result.text = "Enter all four coordinates in decimal degrees (N and E positive)."
			return
		v.append(t.to_float())
	var s := LunarNav.solve(v[0], v[1], v[2], v[3])
	_plot_result.text = "Range %s     Bearing %03d deg\nNorth %+.0f m     East %+.0f m\nD-lat %+.5f deg     D-lon %+.5f deg" % [
		LunarNav.fmt_dist(float(s["range_m"])), int(round(float(s["bearing_deg"]))) % 360,
		float(s["north_m"]), float(s["east_m"]), v[2] - v[0], v[3] - v[1]]


# ================================================================= layout

func _show_page(i: int) -> void:
	_page = i
	for k in _pages.size():
		_pages[k].visible = k == i
		_page_buttons[k].disabled = k == i
	_refresh()


func _cycle_mode() -> void:
	_rel_mode = (_rel_mode + 1) % REL_NAMES.size()
	_mode_button.text = "View: " + REL_NAMES[_rel_mode]
	_refresh()


func _do_fix(id: String) -> void:
	_set_status(LunarNav.fix_landmark(id))
	_refresh()


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(1180, 640)
	var sb := _box(PANEL_BG, PANEL_BORDER, 10, 2)
	sb.content_margin_left = 22.0
	sb.content_margin_right = 22.0
	sb.content_margin_top = 16.0
	sb.content_margin_bottom = 14.0
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	outer.add_child(header)
	var title := _label("NAV SLATE", 26, ACCENT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	for i in PAGE_NAMES.size():
		var b := Button.new()
		b.text = PAGE_NAMES[i]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(170, 0)
		b.pressed.connect(_show_page.bind(i))
		header.add_child(b)
		_page_buttons.append(b)
	var close_button := Button.new()
	close_button.text = "Close (N)"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)
	outer.add_child(HSeparator.new())

	var stack := VBoxContainer.new()
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(stack)

	# --- page 0: mission control
	var p0 := VBoxContainer.new()
	p0.add_theme_constant_override("separation", 8)
	stack.add_child(p0)
	_mode_button = Button.new()
	_mode_button.text = "View: " + REL_NAMES[0]
	_mode_button.focus_mode = Control.FOCUS_NONE
	_mode_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_mode_button.pressed.connect(_cycle_mode)
	p0.add_child(_mode_button)
	_mc_text = _mono_label(15)
	p0.add_child(_mc_text)
	_pages.append(p0)

	# --- page 1: nav computer
	var p1 := VBoxContainer.new()
	p1.add_theme_constant_override("separation", 8)
	stack.add_child(p1)
	_nav_text = _mono_label(15)
	p1.add_child(_nav_text)
	var fix_row := HBoxContainer.new()
	fix_row.add_theme_constant_override("separation", 10)
	p1.add_child(fix_row)
	var fc := Button.new()
	fc.text = "Touch fix: crash site"
	fc.focus_mode = Control.FOCUS_NONE
	fc.pressed.connect(_do_fix.bind("crash"))
	fix_row.add_child(fc)
	var fb := Button.new()
	fb.text = "Touch fix: base"
	fb.focus_mode = Control.FOCUS_NONE
	fb.pressed.connect(_do_fix.bind("base"))
	fix_row.add_child(fb)
	_pages.append(p1)

	# --- page 2: plotter
	var p2 := VBoxContainer.new()
	p2.add_theme_constant_override("separation", 10)
	stack.add_child(p2)
	p2.add_child(_label("Range and bearing between two coordinates. Work out where you are and where you want to go, then type the numbers in.", 15, TEXT_DIM))
	_assist = CheckButton.new()
	_assist.text = "Assist: fill the fields from mission control's points and the DR position"
	_assist.focus_mode = Control.FOCUS_NONE
	_assist.toggled.connect(_on_assist_toggled)
	p2.add_child(_assist)
	_opts_row = HBoxContainer.new()
	(_opts_row as HBoxContainer).add_theme_constant_override("separation", 10)
	_opts_row.visible = false
	p2.add_child(_opts_row)
	_opts_row.add_child(_label("From", 15, TEXT))
	_from_opt = OptionButton.new()
	_from_opt.focus_mode = Control.FOCUS_NONE
	_from_opt.item_selected.connect(_on_option_selected.bind(true))
	_opts_row.add_child(_from_opt)
	_opts_row.add_child(_label("To", 15, TEXT))
	_to_opt = OptionButton.new()
	_to_opt.focus_mode = Control.FOCUS_NONE
	_to_opt.item_selected.connect(_on_option_selected.bind(false))
	_opts_row.add_child(_to_opt)
	p2.add_child(_coord_row("from", "FROM"))
	p2.add_child(_coord_row("to", "TO  "))
	var compute := Button.new()
	compute.text = "Compute"
	compute.focus_mode = Control.FOCUS_NONE
	compute.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	compute.pressed.connect(_on_compute)
	p2.add_child(compute)
	_plot_result = _mono_label(18)
	p2.add_child(_plot_result)
	_pages.append(p2)

	outer.add_child(HSeparator.new())
	_status = _label("", 16, GOOD)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(_status)


func _coord_row(prefix: String, title: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.add_child(_mono_title(title))
	for part in ["lat", "lon"]:
		var e := LineEdit.new()
		e.placeholder_text = "%s (deg)" % part
		e.custom_minimum_size = Vector2(190, 0)
		row.add_child(e)
		_fields[prefix + "_" + part] = e
	return row


func _mono_title(text: String) -> Label:
	var l := _label(text, 16, ACCENT)
	l.add_theme_font_override("font", _mono)
	return l


func _mono_label(size: int) -> Label:
	var l := _label("", size, TEXT)
	l.add_theme_font_override("font", _mono)
	return l


func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _box(bg: Color, border: Color, radius: int, border_width: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(border_width)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb
