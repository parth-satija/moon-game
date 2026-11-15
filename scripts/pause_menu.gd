extends CanvasLayer
## Pause menu, created by the GameState autoload. Esc opens it while playing (the game is paused behind it),
## Esc again or "Resume" closes it. It also shows a small "Game saved" note whenever GameState saves.
##
## Esc is left alone while the inventory window is open, so that Esc still closes the inventory first.

const PANEL_BG := Color(0.04, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.55, 0.65, 0.8, 0.7)
const TEXT := Color(0.93, 0.95, 1.0)
const ACCENT := Color(1.0, 0.75, 0.35)

var _root: Control
var _toast: Label
var _toast_tween: Tween


func _ready() -> void:
	layer = 30                                           # above the inventory (10) and dialogue (20)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	GameState.saved.connect(_on_saved)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		return
	if _root.visible:
		_resume()
		get_viewport().set_input_as_handled()
	elif GameState.in_game and not Inventory.ui_open:
		_open()
		get_viewport().set_input_as_handled()


func _open() -> void:
	_root.visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _resume() -> void:
	_root.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_save_pressed() -> void:
	GameState.save_now()


func _on_menu_pressed() -> void:
	_root.visible = false
	GameState.leave_to_menu()


func _on_quit_pressed() -> void:
	GameState.quit_game()


func _on_saved(_slot: int) -> void:
	if not GameState.in_game:
		return
	_toast.text = "Game saved"
	_toast.modulate.a = 1.0
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.2)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.6)


func _build_ui() -> void:
	_toast = Label.new()
	_toast.anchor_left = 1.0
	_toast.anchor_right = 1.0
	_toast.anchor_top = 0.0
	_toast.anchor_bottom = 0.0
	_toast.offset_left = -220.0
	_toast.offset_right = -16.0
	_toast.offset_top = 12.0
	_toast.offset_bottom = 40.0
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_toast.add_theme_font_size_override("font_size", 15)
	_toast.add_theme_color_override("font_color", Color(0.55, 0.9, 0.55))
	_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.modulate.a = 0.0
	add_child(_toast)

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = PANEL_BORDER
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(24.0)
	panel.add_theme_stylebox_override("panel", sb)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 0)
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", ACCENT)
	box.add_child(title)

	_add_button(box, "Resume", _resume)
	_add_button(box, "Save game", _on_save_pressed)
	_add_button(box, "Save and main menu", _on_menu_pressed)
	_add_button(box, "Save and quit", _on_quit_pressed)

	var hint := Label.new()
	hint.text = "The game also saves by itself every few seconds."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	box.add_child(hint)


func _add_button(parent: Control, text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(handler)
	parent.add_child(b)
