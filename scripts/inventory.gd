extends Node
## Autoload "Inventory": item counts and item definitions. Repairs (the things materials are spent on) live in
## repairs.gd. Item counts are saved in the active save slot by GameState.
##
##     Inventory.add_items({Mat.ALLOY: 2})           # positive integer counts only
##     Inventory.get_count(Mat.ALLOY)
##     Inventory.has_items({...}) / Inventory.remove_items({...})
##     Inventory.changed.connect(...)                # fires after any add / remove / set
##
## To add an item, add an entry to ITEMS (and a constant in materials.gd). The inventory window
## (inventory_ui.gd) is built from this table. RECIPES is kept for item-to-item crafting but is empty:
## the materials are consumed by repairs now.

signal changed
signal crafted(recipe_id: String)

const SAVE_PATH := "user://inventory.cfg"

const ITEMS := {
	Mat.ALLOY: {
		"kind": "Material", "short": "Alloy Plates", "color": Color(0.62, 0.67, 0.74),
		"desc": "Hull and frame plating salvaged from wrecks.",
	},
	Mat.WIRING: {
		"kind": "Material", "short": "Wiring", "color": Color(0.90, 0.55, 0.25),
		"desc": "Insulated electrical cable, still mostly intact.",
	},
	Mat.CIRCUIT: {
		"kind": "Material", "short": "Circuit Boards", "color": Color(0.35, 0.75, 0.45),
		"desc": "Control and power boards.",
	},
	Mat.BATTERY: {
		"kind": "Material", "short": "Battery Modules", "color": Color(0.55, 0.85, 0.45),
		"desc": "Rechargeable storage cells.",
	},
	Mat.SOLAR: {
		"kind": "Material", "short": "Solar Cells", "color": Color(0.30, 0.45, 0.95),
		"desc": "Photovoltaic cell modules.",
	},
	Mat.MECHANICAL: {
		"kind": "Material", "short": "Mech. Assemblies", "color": Color(0.80, 0.72, 0.45),
		"desc": "Gears, joints, bearings and actuators.",
	},
	Mat.HYDRAULIC: {
		"kind": "Material", "short": "Hydraulics", "color": Color(0.45, 0.80, 0.95),
		"desc": "Pumps, lines and pistons.",
	},
	Mat.THERMAL: {
		"kind": "Material", "short": "Thermal Seals", "color": Color(0.90, 0.78, 0.60),
		"desc": "Seals, gaskets and insulation layers.",
	},
	Mat.AVIONICS: {
		"kind": "Material", "short": "Avionics", "color": Color(0.75, 0.55, 0.95),
		"desc": "Flight computers and sensors.",
	},
	Mat.PROPULSION: {
		"kind": "Material", "short": "Propulsion", "color": Color(0.95, 0.45, 0.50),
		"desc": "Engine and fuel-system parts.",
	},
}

const RECIPES := {}

## True while the inventory window is open. The player script reads this to stop moving and looking.
var ui_open := false

## The GameState autoload turns this off: each save slot stores its own inventory instead of the shared file.
var legacy_file_enabled := true

var _items: Dictionary = {}


func _init() -> void:
	for item_name in ITEMS:
		_items[item_name] = 0


func _ready() -> void:
	var config := ConfigFile.new()
	var error := config.load(SAVE_PATH)
	if error == ERR_FILE_NOT_FOUND:
		return
	if error != OK:
		push_error("Could not load inventory: %s" % error_string(error))
		return

	var saved_items: Variant = config.get_value("inventory", "items", {})
	if not saved_items is Dictionary:
		push_error("Saved inventory data is not a dictionary.")
		return
	for item_name in saved_items:
		if not ITEMS.has(str(item_name)):
			continue                                   # items from older versions of the game
		var count: Variant = saved_items[item_name]
		if typeof(count) != TYPE_INT or count < 0:
			push_error("Saved inventory count for %s is invalid." % item_name)
			continue
		_items[str(item_name)] = count
	changed.emit()


func get_count(item_name: String) -> int:
	return int(_items.get(item_name, 0))


## Copy of every item name -> count (including zero counts of known items).
func get_items() -> Dictionary:
	return _items.duplicate()


## Replaces all counts (used when a save slot is loaded). Items that no longer exist are dropped.
func set_items(counts: Dictionary) -> void:
	for item_name in _items.keys():
		_items[item_name] = 0
	for item_name in counts:
		var count := int(counts[item_name])
		if count >= 0 and ITEMS.has(str(item_name)):
			_items[str(item_name)] = count
	changed.emit()


## Back to an empty inventory (new game).
func reset() -> void:
	set_items({})


## Display info for an item, with defaults for items that have no entry in ITEMS.
func item_info(item_name: String) -> Dictionary:
	var info: Dictionary = ITEMS.get(item_name, {})
	return {
		"kind": info.get("kind", "Item"),
		"short": info.get("short", item_name),
		"color": info.get("color", Color(0.7, 0.7, 0.7)),
		"desc": info.get("desc", ""),
	}


func add_items(additions: Dictionary) -> void:
	if not _valid_counts(additions):
		push_error("Inventory additions must be positive integer counts.")
		return
	for item_name in additions:
		_items[str(item_name)] = get_count(str(item_name)) + int(additions[item_name])
	_save()
	changed.emit()


func has_items(costs: Dictionary) -> bool:
	for item_name in costs:
		if get_count(str(item_name)) < int(costs[item_name]):
			return false
	return true


## Removes the items if there are enough of all of them. Returns false (and changes nothing) otherwise.
func remove_items(costs: Dictionary) -> bool:
	if not _valid_counts(costs):
		push_error("Inventory removals must be positive integer counts.")
		return false
	if not has_items(costs):
		return false
	for item_name in costs:
		_items[str(item_name)] = get_count(str(item_name)) - int(costs[item_name])
	_save()
	changed.emit()
	return true


func can_craft(recipe_id: String) -> bool:
	return RECIPES.has(recipe_id) and has_items(RECIPES[recipe_id]["inputs"])


## Consumes the recipe's inputs and adds its outputs. Returns false if the recipe is unknown or
## the ingredients are missing.
func craft(recipe_id: String) -> bool:
	if not can_craft(recipe_id):
		return false
	var recipe: Dictionary = RECIPES[recipe_id]
	var inputs: Dictionary = recipe["inputs"]
	var outputs: Dictionary = recipe["outputs"]
	for item_name in inputs:
		_items[str(item_name)] = get_count(str(item_name)) - int(inputs[item_name])
	for item_name in outputs:
		_items[str(item_name)] = get_count(str(item_name)) + int(outputs[item_name])
	_save()
	changed.emit()
	crafted.emit(recipe_id)
	return true


func _valid_counts(counts: Dictionary) -> bool:
	for item_name in counts:
		var amount: Variant = counts[item_name]
		if typeof(amount) != TYPE_INT or amount <= 0:
			return false
	return true


func _save() -> void:
	if not legacy_file_enabled:
		return
	var config := ConfigFile.new()
	config.set_value("inventory", "items", _items)
	var error := config.save(SAVE_PATH)
	if error != OK:
		push_error("Could not save inventory: %s" % error_string(error))
