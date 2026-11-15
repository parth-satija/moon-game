extends Node
## Autoload "Repairs": the repair list, mission progression, and where the materials come from.
## Progress (repairs done, sources already salvaged) is saved in the active slot by GameState.
##
## Progression: the stages below are done in order. A stage unlocks once the one before it is complete.
## Repairs are crafted only at the crafter (crafter.gd): using it opens the repair window and sets crafter_open,
## and nothing can be repaired while that is false. The inventory window opened with I shows materials only.
##
##     Repairs.is_done("suit_oxygen_filter")        Repairs.stage_complete("base")
##     Repairs.block_reason(id)                     Repairs.repair(id)
##     Repairs.salvage("wreck")                     Repairs.objective_text()
##     Repairs.repaired.connect(...)                Repairs.stage_completed.connect(...)
##
## To change costs, drops or stages, edit the tables here: STAGES, REPAIRS, LOOT (POOL is only a checksum).

signal changed
signal repaired(repair_id: String)
signal stage_completed(stage_id: String)

## Ordered stages. "done_line" is spoken when the stage is finished.
const STAGES := [
	{"id": "suit", "name": "Survival systems",
		"done_line": "Suit systems are stable. The lunar base is next."},
	{"id": "base", "name": "Lunar base",
		"done_line": "Base power is back online. The solar panels are next."},
	{"id": "solar", "name": "Solar panels",
		"done_line": "The solar array is feeding the base. Now the buggy."},
	{"id": "buggy", "name": "Lunar buggy",
		"done_line": "The buggy checks out green. Its winch can lift the Starship at the crash site."},
	{"id": "rocket", "name": "Return spacecraft",
		"done_line": "All spacecraft systems nominal. It needs fuel: the base's propellant plant makes it, and the buggy can haul it."},
]

## Lines spoken when a stage opens, i.e. right after the stage before it is finished (see repair()). Each line is
## [speaker, text]; the reading time comes from the text length. Mission control only ever talks navigation here.
const STAGE_INTRO := {
	"base": [
		["Suit computer", "Base power systems are offline."],
		["Astronaut", "Let's get the essential systems running again."],
		["Mission Control", "The base is the one position you can always fix on, Eagle. Touch-fix on its hull from the nav slate (N) before you head out."],
		["Mission Control", "Finish the base repairs and we will uplink the drop point for the solar array."],
	],
	"buggy": [
		["Suit computer", "Rover repairs required before operation."],
		["Astronaut", "Almost there. I need to get this vehicle working."],
		["Mission Control", "Once the buggy runs, its wheel odometer will over-read on loose regolith. Re-fix on the base or the crash site after any long drive."],
	],
}

const REPAIRS := [
	# --- suit and life support
	{"id": "suit_oxygen_filter", "stage": "suit", "name": "Suit Oxygen Filter",
		"desc": "Replace the clogged filter cartridge.",
		"cost": {Mat.THERMAL: 1, Mat.CIRCUIT: 1}},
	{"id": "suit_electrical", "stage": "suit", "name": "Suit Electrical System",
		"desc": "Rewire the suit's power bus.",
		"cost": {Mat.WIRING: 1, Mat.CIRCUIT: 1}},
	{"id": "suit_oxygen_connection", "stage": "suit", "name": "Oxygen Supply Connection",
		"desc": "Reseat and seal the oxygen line.",
		"cost": {Mat.WIRING: 1, Mat.THERMAL: 1}},
	# --- lunar base
	{"id": "base_structure", "stage": "base", "name": "Base Structural Damage",
		"desc": "Patch the breached hull sections.",
		"cost": {Mat.ALLOY: 3, Mat.THERMAL: 1}},
	{"id": "base_power_controller", "stage": "base", "name": "Base Power Controller",
		"desc": "Replace the burnt-out controller board.",
		"cost": {Mat.CIRCUIT: 1, Mat.WIRING: 2}},
	{"id": "base_emergency_power", "stage": "base", "name": "Emergency Power Storage",
		"desc": "Install fresh cells in the backup bank.",
		"cost": {Mat.BATTERY: 2, Mat.CIRCUIT: 1}},
	{"id": "base_electrical", "stage": "base", "name": "Base Electrical Connections",
		"desc": "Restore the severed distribution lines.",
		"cost": {Mat.WIRING: 2, Mat.CIRCUIT: 1}},
	# --- solar panels
	{"id": "solar_panel", "stage": "solar", "name": "Damaged Solar Panel",
		"desc": "Swap out the cracked cell modules.",
		"cost": {Mat.SOLAR: 2, Mat.WIRING: 1}},
	{"id": "solar_positioning", "stage": "solar", "name": "Solar Panel Positioning Mechanism",
		"desc": "Free the sun-tracking drive.",
		"cost": {Mat.MECHANICAL: 1, Mat.HYDRAULIC: 1}},
	{"id": "solar_controller", "stage": "solar", "name": "Solar Panel Power Controller",
		"desc": "Replace the charge controller.",
		"cost": {Mat.CIRCUIT: 1, Mat.WIRING: 1}},
	# --- lunar buggy (LRV)
	{"id": "buggy_wheels", "stage": "buggy", "name": "Wheel and Suspension System",
		"desc": "Rebuild the wheel hubs and springs.",
		"cost": {Mat.MECHANICAL: 2, Mat.ALLOY: 1}},
	{"id": "buggy_steering", "stage": "buggy", "name": "Steering System",
		"desc": "Repair the steering actuators.",
		"cost": {Mat.HYDRAULIC: 1, Mat.MECHANICAL: 1}},
	{"id": "buggy_chassis", "stage": "buggy", "name": "Damaged Chassis",
		"desc": "Straighten and reinforce the frame.",
		"cost": {Mat.ALLOY: 3, Mat.MECHANICAL: 1}},
	{"id": "buggy_electrical", "stage": "buggy", "name": "Buggy Electrical System",
		"desc": "Replace the drive controller and harness.",
		"cost": {Mat.CIRCUIT: 1, Mat.WIRING: 2}},
	{"id": "buggy_battery", "stage": "buggy", "name": "Buggy Battery System",
		"desc": "Install new battery modules.",
		"cost": {Mat.BATTERY: 2, Mat.WIRING: 1}},
	# --- return spacecraft
	{"id": "rocket_structure", "stage": "rocket", "name": "External Structural Damage",
		"desc": "Plate over the damaged outer skin.",
		"cost": {Mat.ALLOY: 5, Mat.THERMAL: 2}},
	{"id": "rocket_fuel", "stage": "rocket", "name": "Fuel Delivery System",
		"desc": "Rebuild the feed lines and valves.",
		"cost": {Mat.PROPULSION: 1, Mat.THERMAL: 2, Mat.WIRING: 2}},
	{"id": "rocket_engine_control", "stage": "rocket", "name": "Engine Control System",
		"desc": "Replace the engine controller.",
		"cost": {Mat.CIRCUIT: 2, Mat.AVIONICS: 1}},
	{"id": "rocket_propulsion", "stage": "rocket", "name": "Propulsion Assembly",
		"desc": "Refit the engine and gimbal.",
		"cost": {Mat.PROPULSION: 1, Mat.MECHANICAL: 2}},
	{"id": "rocket_navigation", "stage": "rocket", "name": "Navigation and Flight Control",
		"desc": "Restore guidance and flight control.",
		"cost": {Mat.AVIONICS: 1, Mat.CIRCUIT: 1}},
	{"id": "rocket_power", "stage": "rocket", "name": "Electrical and Power System",
		"desc": "Power the spacecraft's systems.",
		"cost": {Mat.BATTERY: 1, Mat.WIRING: 2}},
]

## Everything that exists in the world, per material. LOOT must add up to exactly this (checked at start-up).
## Each amount is at least what all 21 repairs need together (alloy 12, wiring 15, circuits 10, batteries 5,
## solar cells 2, mechanical 7, hydraulics 2, thermal 7, avionics 2, propulsion 2), plus spare solar cells,
## alloy, hydraulic parts and one mechanical assembly (the spares are under the lifted Starship).
const POOL := {
	Mat.ALLOY: 18, Mat.WIRING: 15, Mat.CIRCUIT: 10, Mat.BATTERY: 5, Mat.SOLAR: 4,
	Mat.MECHANICAL: 8, Mat.HYDRAULIC: 4, Mat.THERMAL: 7, Mat.AVIONICS: 2, Mat.PROPULSION: 2,
}

## What each salvage source gives, once. Keys are WorldSite salvage ids: "wreck" (the crashed Starship),
## "wreck_underside" (the hull's underside, open once the buggy has lifted the Starship), and the node names
## GameState gives the placed objects.
const LOOT := {
	"wreck": {Mat.ALLOY: 6, Mat.WIRING: 3, Mat.CIRCUIT: 3, Mat.THERMAL: 4, Mat.AVIONICS: 2, Mat.PROPULSION: 2, Mat.MECHANICAL: 1},
	"InteriorBase": {Mat.ALLOY: 2, Mat.WIRING: 3, Mat.CIRCUIT: 3, Mat.BATTERY: 2, Mat.THERMAL: 3},
	"Rover1_1": {Mat.ALLOY: 3, Mat.WIRING: 3, Mat.CIRCUIT: 2, Mat.BATTERY: 1, Mat.SOLAR: 2, Mat.MECHANICAL: 2, Mat.HYDRAULIC: 1},
	"Rover1_2": {Mat.ALLOY: 3, Mat.WIRING: 4, Mat.CIRCUIT: 1, Mat.BATTERY: 1, Mat.SOLAR: 1, Mat.MECHANICAL: 3, Mat.HYDRAULIC: 1},
	"Rover1_3": {Mat.ALLOY: 2, Mat.WIRING: 2, Mat.CIRCUIT: 1, Mat.BATTERY: 1, Mat.SOLAR: 1, Mat.MECHANICAL: 1, Mat.HYDRAULIC: 1},
	"wreck_underside": {Mat.ALLOY: 2, Mat.MECHANICAL: 1, Mat.HYDRAULIC: 1},
}
const LOOT_FALLBACK := "Rover1_3"                 # a rover1 that is not part of the layout (e.g. the demo rover)

## True while the crafter window is open (set by InventoryUI). Repairs can only be made while it is.
var crafter_open := false

## Saved one-off events. FLAG_WRECK_LIFTED is set when the buggy has lifted the crashed Starship.
const FLAG_WRECK_LIFTED := "wreck_lifted"
const FLAG_FIRST_SALVAGE := "first_salvage_said"       # the astronaut's remarks on the first salvage have been spoken
const FLAG_ROCKET_REPAIRS := "rocket_repairs_said"     # ... and the suit's remarks on the first spacecraft repair

var _done := {}
var _salvaged := {}
var _flags := {}
var _repair_index := {}                           # id -> entry of REPAIRS
var _stage_index := {}                            # id -> position in STAGES


func _ready() -> void:
	for r in REPAIRS:
		_repair_index[str(r["id"])] = r
	for i in STAGES.size():
		_stage_index[str(STAGES[i]["id"])] = i
	if OS.is_debug_build():
		_check_numbers()


# ================================================================= repairs

func repairs_in(stage_id: String) -> Array:
	var out: Array = []
	for r in REPAIRS:
		if str(r["stage"]) == stage_id:
			out.append(r)
	return out


func is_done(repair_id: String) -> bool:
	return _done.has(repair_id)


## x = repairs done in the stage, y = repairs in the stage.
func stage_progress(stage_id: String) -> Vector2i:
	var total := 0
	var done := 0
	for r in repairs_in(stage_id):
		total += 1
		if is_done(str(r["id"])):
			done += 1
	return Vector2i(done, total)


func stage_complete(stage_id: String) -> bool:
	var p := stage_progress(stage_id)
	return p.y > 0 and p.x == p.y


func stage_name(stage_id: String) -> String:
	return str(STAGES[int(_stage_index.get(stage_id, 0))]["name"])


## A stage is open once the one before it is complete (the first is always open).
func stage_unlocked(stage_id: String) -> bool:
	var i := int(_stage_index.get(stage_id, -1))
	if i < 0:
		return false
	return i == 0 or stage_complete(str(STAGES[i - 1]["id"]))


## "" when the repair can be done right now, otherwise the reason it cannot.
func block_reason(repair_id: String) -> String:
	var r: Dictionary = _repair_index.get(repair_id, {})
	if r.is_empty():
		return "Unknown repair"
	if is_done(repair_id):
		return "Repaired"
	var stage_id := str(r["stage"])
	if not stage_unlocked(stage_id):
		var prev := str(STAGES[int(_stage_index[stage_id]) - 1]["name"])
		return "Locked: finish \"%s\" first" % prev
	if not crafter_open:
		return "Use the crafter"
	if not Inventory.has_items(r["cost"]):
		return "Missing materials"
	return ""


func can_repair(repair_id: String) -> bool:
	return block_reason(repair_id) == ""


func repair(repair_id: String) -> bool:
	if not can_repair(repair_id):
		return false
	var r: Dictionary = _repair_index[repair_id]
	if not Inventory.remove_items(r["cost"]):
		return false
	_done[repair_id] = true
	repaired.emit(repair_id)
	var stage_id := str(r["stage"])
	if stage_complete(stage_id):
		stage_completed.emit(stage_id)
		Dialogue.say(str(STAGES[int(_stage_index[stage_id])]["done_line"]), 5.0)
		var next_i := int(_stage_index[stage_id]) + 1
		if next_i < STAGES.size():
			var intro: Array = STAGE_INTRO.get(str(STAGES[next_i]["id"]), [])
			_say_lines(intro)
	else:
		Dialogue.say("%s repaired." % str(r["name"]), 3.0)
		if stage_id == "rocket" and not _flags.has(FLAG_ROCKET_REPAIRS):
			_flags[FLAG_ROCKET_REPAIRS] = true
			var p := stage_progress(stage_id)
			Dialogue.say("Critical spacecraft systems require attention. %d of %d repairs remain." % [p.y - p.x, p.y], 0.0, "Suit computer")
			Dialogue.say("I'll have to restore the essential systems before launch.", 0.0, "Astronaut")
	changed.emit()
	return true


## One line for the HUD: what to do next (plus an optional second line once the buggy is repaired). Once every
## repair is done it is the fuel-and-launch objective (Life.objective_text).
func objective_text() -> String:
	var text := ""
	for s in STAGES:
		var sid := str(s["id"])
		if stage_complete(sid):
			continue
		var p := stage_progress(sid)
		text = "Repair %s (%d/%d) at the base crafter" % [str(s["name"]).to_lower(), p.x, p.y]
		break
	if text == "":
		text = Life.objective_text()
	if stage_complete("buggy") and not has_flag(FLAG_WRECK_LIFTED):
		text += "\nOptional: drive the buggy to the crash site and lift the Starship (F)"
	return text


func _say_lines(lines: Array) -> void:
	for line in lines:
		Dialogue.say(str(line[1]), 0.0, str(line[0]))


func repair_name(repair_id: String) -> String:
	var r: Dictionary = _repair_index.get(repair_id, {})
	return str(r.get("name", repair_id))


# ================================================================= one-off events

func has_flag(flag_id: String) -> bool:
	return _flags.has(flag_id)


func set_flag(flag_id: String, on := true) -> void:
	if on == _flags.has(flag_id):
		return
	if on:
		_flags[flag_id] = true
	else:
		_flags.erase(flag_id)
	changed.emit()


# ================================================================= salvage

func loot_for(source_id: String) -> Dictionary:
	if LOOT.has(source_id):
		return LOOT[source_id]
	if source_id.to_lower().begins_with("rover"):
		return LOOT[LOOT_FALLBACK]
	return {}


func is_salvaged(source_id: String) -> bool:
	return _salvaged.has(source_id)


## Gives the source's loot to the player, once. Returns true if something was taken.
func salvage(source_id: String) -> bool:
	if _salvaged.has(source_id):
		Dialogue.say("There is nothing useful left here.", 2.5)
		return false
	var loot := loot_for(source_id)
	if loot.is_empty():
		Dialogue.say("Nothing here worth taking.", 2.5)
		return false
	_salvaged[source_id] = true
	Inventory.add_items(loot)
	var parts: Array[String] = []
	for item_name in loot:
		parts.append("%dx %s" % [int(loot[item_name]), str(Inventory.item_info(str(item_name))["short"])])
	Dialogue.say("Salvaged: " + ", ".join(parts), 5.0)
	if not _flags.has(FLAG_FIRST_SALVAGE):
		_flags[FLAG_FIRST_SALVAGE] = true
		Dialogue.say("These components might be useful for repairs.", 0.0, "Astronaut")
		Dialogue.say("I should collect only what I need.", 0.0, "Astronaut")
	changed.emit()
	return true


# ================================================================= saving

func get_state() -> Dictionary:
	return {"done": _done.keys(), "salvaged": _salvaged.keys(), "flags": _flags.keys()}


func set_state(state: Dictionary) -> void:
	_done.clear()
	_salvaged.clear()
	_flags.clear()
	for id in state.get("flags", []):
		_flags[str(id)] = true
	for id in state.get("done", []):
		if _repair_index.has(str(id)):
			_done[str(id)] = true
	for id in state.get("salvaged", []):
		_salvaged[str(id)] = true
	changed.emit()


func reset() -> void:
	set_state({})


# ================================================================= bookkeeping

## Total material cost of every repair (or of one stage).
func total_cost(stage_id := "") -> Dictionary:
	var total := {}
	for r in REPAIRS:
		if stage_id != "" and str(r["stage"]) != stage_id:
			continue
		for item_name in r["cost"]:
			total[item_name] = int(total.get(item_name, 0)) + int(r["cost"][item_name])
	return total


# Debug builds: LOOT must add up to POOL, and anything the repairs need beyond POOL is reported.
func _check_numbers() -> void:
	var loot_total := {}
	for src in LOOT:
		for item_name in LOOT[src]:
			loot_total[item_name] = int(loot_total.get(item_name, 0)) + int(LOOT[src][item_name])
	for item_name in POOL:
		if int(loot_total.get(item_name, 0)) != int(POOL[item_name]):
			push_warning("Repairs: LOOT gives %d x %s but POOL says %d" % [int(loot_total.get(item_name, 0)), item_name, int(POOL[item_name])])
	var need := total_cost()
	for item_name in need:
		var short := int(need[item_name]) - int(POOL.get(item_name, 0))
		if short > 0:
			print("Repairs: all repairs need %d x %s but only %d exist (short by %d)" % [int(need[item_name]), item_name, int(POOL.get(item_name, 0)), short])
