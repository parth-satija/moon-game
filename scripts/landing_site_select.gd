extends Control
## Landing-site picker. Shows the Moon's near (front) side as a globe; click to choose a spot,
## then "Land here" exports the longitude/latitude and loads the game scene.
##
## Exported values: the LandingSite autoload (LandingSite.lon_deg / lat_deg), plus the
## site_confirmed signal on this node.

signal site_confirmed(lon_deg: float, lat_deg: float)

@export_file("*.tscn", "*.scn") var next_scene := "res://scenes/landing_sequence.tscn"

@onready var globe: Control = %Globe
@onready var marker: Control = %Marker
@onready var readout: Label = %Readout
@onready var confirm_button: Button = %ConfirmButton

var _hover := Vector2.INF       # disc coords (x east, y north, -1..1), INF = none
var _selected := Vector2.INF
var _lon_deg := 0.0
var _lat_deg := 0.0
var _severity := 0
var _warn_panel: PanelContainer
var _warn_title: Label
var _warn_body: Label

const SEVERITY_COLORS := [Color(0.45, 0.85, 0.6), Color(1.0, 0.7, 0.25), Color(1.0, 0.3, 0.28)]
const SEVERITY_TITLES := ["Site conditions: manageable", "Site conditions: caution", "Site conditions: dangerous"]


func _ready() -> void:
	resized.connect(_layout)
	globe.gui_input.connect(_on_globe_input)
	globe.mouse_exited.connect(_on_globe_exited)
	marker.draw.connect(_draw_marker)
	confirm_button.pressed.connect(_confirm)
	_build_warnings()
	_layout()


# Esc goes back to the main menu (the slot is saved).
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		GameState.leave_to_menu()
		get_viewport().set_input_as_handled()


func _layout() -> void:
	var top := 70.0
	var bottom := 100.0
	var s := maxf(minf(size.x * 0.92, size.y - top - bottom), 100.0)
	globe.size = Vector2(s, s)
	globe.position = Vector2((size.x - s) * 0.5, top + (size.y - top - bottom - s) * 0.5)
	marker.queue_redraw()


# Orthographic disc <-> lon/lat. Mirrors the shader: lon = atan2(x, z), lat = asin(y), z >= 0.
static func disc_to_lonlat(p: Vector2) -> Vector2:
	var z := sqrt(maxf(0.0, 1.0 - p.length_squared()))
	return Vector2(rad_to_deg(atan2(p.x, z)), rad_to_deg(asin(clampf(p.y, -1.0, 1.0))))


static func lonlat_to_disc(lon_deg: float, lat_deg: float) -> Vector2:
	var lon := deg_to_rad(lon_deg)
	var lat := deg_to_rad(lat_deg)
	return Vector2(cos(lat) * sin(lon), sin(lat))


func _local_to_disc(local: Vector2) -> Vector2:
	var u := local / globe.size
	return Vector2(u.x * 2.0 - 1.0, 1.0 - u.y * 2.0)


func _disc_to_local(p: Vector2) -> Vector2:
	return Vector2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5) * globe.size


func _on_globe_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var p := _local_to_disc(event.position)
		_hover = p if p.length_squared() <= 1.0 else Vector2.INF
		_update_readout()
		marker.queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var p := _local_to_disc(event.position)
		if p.length_squared() > 1.0:
			return
		_selected = p
		var ll := disc_to_lonlat(p)
		_lon_deg = ll.x
		_lat_deg = ll.y
		confirm_button.disabled = false
		_update_warnings()
		_update_readout()
		marker.queue_redraw()


func _on_globe_exited() -> void:
	_hover = Vector2.INF
	_update_readout()
	marker.queue_redraw()


# Warnings for the chosen site: heat / cold for the suit and radio coverage (see MoonSystems.site_forecast).
func _build_warnings() -> void:
	_warn_panel = PanelContainer.new()
	_warn_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_warn_panel.anchor_left = 0.0
	_warn_panel.anchor_right = 0.0
	_warn_panel.offset_left = 20.0
	_warn_panel.offset_right = 380.0
	_warn_panel.offset_top = 80.0
	_warn_panel.offset_bottom = 80.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.07, 0.82)
	sb.border_color = Color(0.55, 0.65, 0.8, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12.0)
	_warn_panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.custom_minimum_size = Vector2(336.0, 0.0)
	box.add_theme_constant_override("separation", 6)
	_warn_panel.add_child(box)
	_warn_title = Label.new()
	_warn_title.add_theme_font_size_override("font_size", 17)
	box.add_child(_warn_title)
	_warn_body = Label.new()
	_warn_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warn_body.add_theme_font_size_override("font_size", 14)
	_warn_body.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	box.add_child(_warn_body)
	_warn_panel.visible = false
	add_child(_warn_panel)


func _update_warnings() -> void:
	var f := MoonSystems.site_forecast(_lon_deg, _lat_deg)
	_severity = clampi(int(f["severity"]), 0, 2)
	_warn_title.text = SEVERITY_TITLES[_severity]
	_warn_title.add_theme_color_override("font_color", SEVERITY_COLORS[_severity])
	_warn_body.text = "\n\n".join(f["lines"])
	_warn_panel.visible = true


func _update_readout() -> void:
	if _hover != Vector2.INF:
		var h := disc_to_lonlat(_hover)
		readout.text = "Cursor: %s" % _format(h.x, h.y)
	elif _selected != Vector2.INF:
		readout.text = "Landing site: %s" % _format(_lon_deg, _lat_deg)
	else:
		readout.text = "Click the Moon to choose a landing site (near side only)"


func _format(lon: float, lat: float) -> String:
	return "%.2f° %s, %.2f° %s" % [absf(lon), "E" if lon >= 0.0 else "W", absf(lat), "N" if lat >= 0.0 else "S"]


func _draw_marker() -> void:
	if _hover != Vector2.INF:
		marker.draw_arc(_disc_to_local(_hover), 7.0, 0.0, TAU, 24, Color(1, 1, 1, 0.6), 1.5, true)
	if _selected != Vector2.INF:
		var c := _disc_to_local(_selected)
		var col: Color = SEVERITY_COLORS[_severity] if _severity > 0 else Color(1.0, 0.55, 0.1)
		marker.draw_arc(c, 11.0, 0.0, TAU, 32, col, 2.5, true)
		marker.draw_line(c + Vector2(-18, 0), c + Vector2(-6, 0), col, 2.0, true)
		marker.draw_line(c + Vector2(6, 0), c + Vector2(18, 0), col, 2.0, true)
		marker.draw_line(c + Vector2(0, -18), c + Vector2(0, -6), col, 2.0, true)
		marker.draw_line(c + Vector2(0, 6), c + Vector2(0, 18), col, 2.0, true)


func _confirm() -> void:
	if _selected == Vector2.INF:
		return
	LandingSite.set_site(_lon_deg, _lat_deg)
	site_confirmed.emit(_lon_deg, _lat_deg)
	if next_scene != "":
		get_tree().change_scene_to_file(next_scene)
