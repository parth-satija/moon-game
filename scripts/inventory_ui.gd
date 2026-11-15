extends CanvasLayer
## Autoload "InventoryUI": the inventory and crafting window. Press I (or Tab) to open / close it,
## Esc closes it too. It is built from the item and recipe tables in inventory.gd and refreshes itself
## whenever Inventory.changed fires, so new items and recipes show up without touching this file.
##
## While it is open the mouse is released and the player stops moving and looking (the player script
## checks Inventory.ui_open). The game keeps running underneath.
##
##     InventoryUI.toggle()   InventoryUI.open()   InventoryUI.close()   InventoryUI.is_open()

const PANEL_BG := Color(0.04, 0.05, 0.08, 0.96)
const PANEL_BORDER := Color(0.55, 0.65, 0.8, 0.7)
const SLOT_BG := Color(0.09, 0.11, 0.16, 0.95)
const TEXT := Color(0.93, 0.95, 1.0)
const TEXT_DIM := Color(0.62, 0.68, 0.78)
const ACCENT := Color(1.0, 0.75, 0.35)
const HAVE := Color(0.55, 0.9, 0.55)
const LACK := Color(0.95, 0.45, 0.4)

var _root: Control
var _grid: GridContainer
var _recipes: VBoxContainer
var _status: Label
var _status_tween: Tween
var _check_cd := 0.0
var _crafting := false                           # true when opened at the crafter: shows the repairs too
var _title: Label
var _right: Control
var _sep: Control
var _hint: Label


func _ready() -> void:
	layer = 10                                   # above the HUD, below the dialogue box (20)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_root.visible = false
	Inventory.changed.connect(_refresh)
	Inventory.crafted.connect(_on_crafted)
	Repairs.changed.connect(_refresh)
	_refresh()


func _exit_tree() -> void:
	if Inventory != null:
		Inventory.ui_open = false
	if Repairs != null:
		Repairs.crafter_open = false


func is_open() -> bool:
	return _root != null and _root.visible


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


## The plain window (I / Tab): materials only. open(true) / open_crafter() is the crafter window, which also
## lists the repairs; it is the only way to make a repair (Repairs.crafter_open is true only while it is up).
func open(crafting := false) -> void:
	if not _player_present(get_tree().root):
		return
	if is_open() and crafting == _crafting:
		return
	_crafting = crafting
	Repairs.crafter_open = crafting
	Inventory.ui_open = true
	_root.visible = true
	_apply_mode()
	_set_status("")
	_refresh()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func open_crafter() -> void:
	open(true)


func _apply_mode() -> void:
	_title.text = "Crafter: repairs" if _crafting else "Inventory"
	_right.visible = _crafting
	_sep.visible = _crafting
	_hint.text = "I / Tab / Esc: close      Repairs are crafted at the crafter" if not _crafting \
		else "I / Tab / Esc: close      Each repair is permanent and uses up its materials"


func close() -> void:
	if not is_open():
		return
	Inventory.ui_open = false
	Repairs.crafter_open = false
	_crafting = false
	_root.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_I or event.keycode == KEY_TAB:
		toggle()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_ESCAPE and is_open():
		close()
		get_viewport().set_input_as_handled()


# If the scene changes while the window is open (the player disappears), shut it instead of leaving
# the mouse free and the controls locked.
func _process(delta: float) -> void:
	if not is_open():
		return
	_check_cd -= delta
	if _check_cd <= 0.0:
		_check_cd = 0.5
		if not _player_present(get_tree().root):
			close()


func _player_present(n: Node) -> bool:
	if n is MoonPlayer:
		return true
	for c in n.get_children():
		if _player_present(c):
			return true
	return false


# ---------------------------------------------------------------- content
func _refresh() -> void:
	if _grid == null:
		return
	_clear(_grid)
	var items := Inventory.get_items()
	for item_name in items:
		_grid.add_child(_make_slot(str(item_name), int(items[item_name])))

	if not _crafting:
		return
	_clear(_recipes)
	for stage in Repairs.STAGES:
		_recipes.add_child(_make_stage_header(stage))
		for r in Repairs.repairs_in(str(stage["id"])):
			_recipes.add_child(_make_repair_row(r))


func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()                           # queue_free: this can run from inside a button's own signal


func _make_slot(item_name: String, count: int) -> Control:
	var info := Inventory.item_info(item_name)
	var col: Color = info["color"]
	var owned := count > 0

	var slot := PanelContainer.new()
	slot.custom_minimum_size = Vector2(128, 104)
	slot.tooltip_text = "%s (%s)\n%s" % [item_name, info["kind"], info["desc"]]
	slot.add_theme_stylebox_override("panel", _box(SLOT_BG, col if owned else Color(0.3, 0.34, 0.42, 0.6), 6, 1))
	slot.modulate.a = 1.0 if owned else 0.5

	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(v)

	var swatch := ColorRect.new()
	swatch.color = col
	swatch.custom_minimum_size = Vector2(34, 34)
	swatch.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(swatch)

	var name_label := _label(str(info["short"]), 15, TEXT)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(name_label)

	var count_label := _label("x%d" % count, 20, ACCENT if owned else TEXT_DIM)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(count_label)
	return slot


func _make_stage_header(stage: Dictionary) -> Control:
	var sid := str(stage["id"])
	var p := Repairs.stage_progress(sid)
	var unlocked := Repairs.stage_unlocked(sid)
	var text := "%s   (%d/%d)" % [str(stage["name"]), p.x, p.y]
	if not unlocked:
		text += "   [locked]"
	elif p.x == p.y:
		text += "   [complete]"
	var l := _label(text, 18, ACCENT if unlocked else TEXT_DIM)
	l.custom_minimum_size = Vector2(0, 30)
	l.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return l


func _make_repair_row(r: Dictionary) -> Control:
	var id := str(r["id"])
	var done := Repairs.is_done(id)
	var reason := Repairs.block_reason(id)
	var can := reason == ""

	var row := PanelContainer.new()
	var border := Color(0.35, 0.5, 0.35, 0.8) if (can or done) else Color(0.3, 0.34, 0.42, 0.6)
	row.add_theme_stylebox_override("panel", _box(SLOT_BG, border, 6, 1))
	row.modulate.a = 0.6 if done else 1.0

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	row.add_child(h)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 3)
	h.add_child(info)
	info.add_child(_label(str(r["name"]), 17, TEXT))

	var desc := _label(str(r["desc"]), 13, TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(240, 0)
	info.add_child(desc)

	var needs := HFlowContainer.new()
	needs.add_theme_constant_override("h_separation", 14)
	info.add_child(needs)
	var cost: Dictionary = r["cost"]
	for item_name in cost:
		var need := int(cost[item_name])
		var have := Inventory.get_count(str(item_name))
		var short := str(Inventory.item_info(str(item_name))["short"])
		needs.add_child(_label("%s %d/%d" % [short, have, need], 14, HAVE if have >= need else LACK))

	if not done and not can:
		var why := _label(reason, 13, LACK if reason == "Missing materials" else TEXT_DIM)
		why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		why.custom_minimum_size = Vector2(240, 0)
		info.add_child(why)

	var button := Button.new()
	button.text = "Repaired" if done else "Repair"
	button.custom_minimum_size = Vector2(92, 44)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.disabled = not can
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(_on_repair_pressed.bind(id))
	h.add_child(button)
	return row


func _on_repair_pressed(repair_id: String) -> void:
	if not Repairs.repair(repair_id):
		_set_status(Repairs.block_reason(repair_id))
	else:
		_set_status("Repair complete.")


func _make_recipe_row(recipe_id: String) -> Control:
	var recipe: Dictionary = Inventory.RECIPES[recipe_id]
	var can := Inventory.can_craft(recipe_id)

	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _box(SLOT_BG, Color(0.35, 0.5, 0.35, 0.8) if can else Color(0.3, 0.34, 0.42, 0.6), 6, 1))

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	row.add_child(h)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 3)
	h.add_child(info)

	var outputs: Dictionary = recipe["outputs"]
	var out_parts: Array[String] = []
	for item_name in outputs:
		out_parts.append("%s x%d" % [item_name, int(outputs[item_name])])
	info.add_child(_label("%s   \u2192   %s" % [recipe["name"], ", ".join(out_parts)], 18, TEXT))

	var desc := _label(str(recipe["desc"]), 14, TEXT_DIM)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(240, 0)
	info.add_child(desc)

	var needs := HFlowContainer.new()
	needs.add_theme_constant_override("h_separation", 16)
	info.add_child(needs)
	var inputs: Dictionary = recipe["inputs"]
	for item_name in inputs:
		var need := int(inputs[item_name])
		var have := Inventory.get_count(str(item_name))
		needs.add_child(_label("%s %d/%d" % [item_name, have, need], 15, HAVE if have >= need else LACK))

	var button := Button.new()
	button.text = "Craft"
	button.custom_minimum_size = Vector2(92, 44)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.disabled = not can
	button.focus_mode = Control.FOCUS_NONE        # keeps Space (jump) from also pressing a focused button
	button.pressed.connect(_on_craft_pressed.bind(recipe_id))
	h.add_child(button)
	return row


func _on_craft_pressed(recipe_id: String) -> void:
	if not Inventory.craft(recipe_id):
		_set_status("Missing ingredients.")


func _on_crafted(recipe_id: String) -> void:
	var recipe: Dictionary = Inventory.RECIPES.get(recipe_id, {})
	_set_status("Crafted %s." % recipe.get("name", recipe_id))


func _set_status(text: String) -> void:
	if _status == null:
		return
	if _status_tween:
		_status_tween.kill()
	_status.text = text
	_status.modulate.a = 1.0
	if text.is_empty():
		return
	_status_tween = create_tween()
	_status_tween.tween_interval(1.8)
	_status_tween.tween_property(_status, "modulate:a", 0.0, 0.5)


# ---------------------------------------------------------------- layout
func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP       # clicks outside the window must not reach the game
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(980, 560)
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

	# header
	var header := HBoxContainer.new()
	outer.add_child(header)
	_title = _label("Inventory", 26, ACCENT)
	var title := _title
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "Close (I)"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	header.add_child(close_button)
	outer.add_child(HSeparator.new())

	# body: items on the left, recipes on the right
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 22)
	outer.add_child(body)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.0
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)
	left.add_child(_label("Inventory", 20, TEXT))
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(left_scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	left_scroll.add_child(_grid)

	_sep = VSeparator.new()
	body.add_child(_sep)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.4
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)
	_right = right
	right.add_child(_label("Repairs", 20, TEXT))
	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(right_scroll)
	_recipes = VBoxContainer.new()
	_recipes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recipes.add_theme_constant_override("separation", 8)
	right_scroll.add_child(_recipes)

	# footer
	var footer := HBoxContainer.new()
	outer.add_child(footer)
	_hint = _label("", 14, TEXT_DIM)
	var hint := _hint
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(hint)
	_status = _label("", 16, HAVE)
	footer.add_child(_status)


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
