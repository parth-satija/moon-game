extends Node
## Autoload "GameState": save slots, continuous autosave, and the persistent layout of the world.
##
## A "session" is one save slot being played. The slot file (user://saves/slot_N.json) is rewritten
## continuously: every AUTOSAVE_INTERVAL_S seconds while playing, whenever the inventory or the repair
## progress changes, when the landing site is picked, when the crash site is first reached, when you go back
## to the menu and when the window is closed. It holds the stage of the game, the landing site and the crash,
## the player's position and view, the inventory, the repair progress (repairs done, sources salvaged) and
## where every placed object stands.
##
## Stages (what "Continue" does):
##     site_select  ->  landing_site_select.tscn
##     landing      ->  landing_sequence.tscn (the picked site is restored first)
##     playing      ->  moon_planet.scn, spawning at the saved position
##
## World layout: the first time a slot reaches the game scene, every entry of WORLD_OBJECTS is placed within
## MAX_DISTANCE_M of the landing site with MoonPlanet.place_scene_flat() (falling back to
## MoonPlanet.place_scene_random()), using a RandomNumberGenerator seeded from the slot and the object's id.
## The exact lon / lat / yaw of every object is then written to the slot, and every later load puts them back
## with MoonPlanet.place_scene(). Objects added to WORLD_OBJECTS later are placed (and saved) the next time an
## old slot is loaded; objects already in the slot never move. A new game gets a new seed, so a new layout.
##
##     GameState.start_new_game(slot)     GameState.continue_game(slot)     GameState.continue_latest()
##     GameState.save_now()               GameState.leave_to_menu()         GameState.quit_game()
##     GameState.slot_summary(slot)       GameState.delete_slot(slot)       GameState.saved.connect(...)

signal saved(slot: int)

const SAVE_DIR := "user://saves"
const SLOT_COUNT := 3
const SAVE_VERSION := 1
const AUTOSAVE_INTERVAL_S := 10.0

const MENU_SCENE := "res://scenes/main_menu.tscn"
const SITE_SELECT_SCENE := "res://scenes/landing_site_select.tscn"
const LANDING_SCENE := "res://scenes/landing_sequence.tscn"
const GAME_SCENE := "res://scenes/moon_planet.scn"      # keep in sync with next_scene in landing_sequence.gd

# --- world layout -------------------------------------------------------------------------------
const MAX_DISTANCE_M := 20000.0                  # everything stays within this distance of the landing site
const FLAT_SEARCH_ATTEMPTS := 80
const SPAWN_MAX_HEIGHT_M := 6.0                  # a spawn higher than this above the exact ground is put on it
## id          node name of the placed scene (also the key in Repairs.LOOT for salvage sites)
## scene       scene to place
## footprint   radius of ground that should be flat under it (metres)
## min         never closer than this to the landing site (metres)
## max         optional: never further than this (default MAX_DISTANCE_M)
## near        optional: id of another entry; min / max are then measured from THAT object instead of from the
##             landing site (it must come earlier in the list)
## rev         optional layout revision (default 1). A saved object with a lower rev is placed again by the
##             current rule, so changing where something goes also moves it in old saves
## slope/rough how tilted (degrees) / bumpy (metres) the patch may be
const WORLD_OBJECTS := [
	{"id": "InteriorBase", "scene": "res://scenes/interior_base.tscn", "footprint": 15.0, "min": 1000.0, "slope": 8.0, "rough": 1.5},
	{"id": "Rover1_1", "scene": "res://scenes/rover1.tscn", "footprint": 6.0, "min": 300.0, "slope": 10.0, "rough": 0.8},
	{"id": "Rover1_2", "scene": "res://scenes/rover1.tscn", "footprint": 6.0, "min": 300.0, "slope": 10.0, "rough": 0.8},
	{"id": "Rover1_3", "scene": "res://scenes/rover1.tscn", "footprint": 6.0, "min": 300.0, "slope": 10.0, "rough": 0.8},
	{"id": "SolarArray", "scene": "res://scenes/solar_array.tscn", "footprint": 10.0, "min": 500.0, "slope": 8.0, "rough": 1.0},
	{"id": "LRV", "scene": "res://scenes/lrv.tscn", "footprint": 5.0, "near": "InteriorBase", "min": 18.0, "max": 35.0, "slope": 10.0, "rough": 0.8, "rev": 2},
	{"id": "ReturnRocket", "scene": "res://scenes/return_rocket.tscn", "footprint": 12.0, "min": 1500.0, "slope": 6.0, "rough": 1.0},
]

var current_slot := 0
var active := false                              # a slot is being played
var in_game := false                             # the game scene (moon_planet.scn) is loaded

var _save: Dictionary = {}
var _moon: MoonPlanet
var _autosave_t := 0.0
var _loading_path := ""
var _loading_layer: CanvasLayer
var _restoring := false                          # LandingSite.set_site() is being called to restore a save, not by the player


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS      # autosave and the scene loader keep running while the pause menu is open
	Inventory.legacy_file_enabled = false        # slots store the inventory now
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	LandingSite.site_selected.connect(_on_site_selected)
	Inventory.changed.connect(_on_progress_changed)
	Repairs.changed.connect(_on_progress_changed)
	get_tree().node_added.connect(_on_node_added)
	var pause_script := load("res://scripts/pause_menu.gd") as GDScript
	if pause_script:
		add_child(pause_script.new())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_now()


const DOCKING_SCENE := "res://scenes/orbital_docking.tscn"
const SKIP_TO_DOCKING_KEY := KEY_Y                # set to KEY_NONE to switch the shortcut off


func _unhandled_input(event: InputEvent) -> void:
	if SKIP_TO_DOCKING_KEY == KEY_NONE or not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == SKIP_TO_DOCKING_KEY and active and in_game and not get_tree().paused and not Inventory.ui_open:
		get_viewport().set_input_as_handled()
		skip_to_docking()


## Y: finishes the game up to the launch. Every repair is done, the spacecraft's tank is full, and you go straight to
## the ascent and docking scene (orbital_docking.tscn). The slot keeps its own progress, with all repairs done.
func skip_to_docking() -> void:
	if not (active and in_game):
		return
	var state := Repairs.get_state()
	var done: Array = []
	for r in Repairs.REPAIRS:
		done.append(str(r["id"]))
	state["done"] = done
	Repairs.set_state(state)
	var life := get_node_or_null("/root/Life")           # the Life autoload may not be registered (project.godot)
	if life != null:
		life.set("rocket_fuel", float(life.get("ROCKET_TANK")))
		life.emit_signal("fuel_changed")
	launch_to_docking()


## Saves and hands over to the ascent and docking scene (the launch of the return spacecraft, return_rocket.gd).
func launch_to_docking() -> void:
	if not (active and in_game):
		return
	save_now()
	LunarNav.end_session()
	in_game = false
	_moon = null
	Inventory.ui_open = false
	get_tree().paused = false
	get_tree().change_scene_to_file(DOCKING_SCENE)


func _process(delta: float) -> void:
	_poll_load()
	if not (active and in_game):
		return
	if _moon == null or not is_instance_valid(_moon):
		in_game = false
		return
	if not get_tree().paused:
		_save["playtime_s"] = float(_save.get("playtime_s", 0.0)) + delta
	_autosave_t += delta
	if _autosave_t >= AUTOSAVE_INTERVAL_S:
		_autosave_t = 0.0
		save_now()


# ================================================================= slots

func slot_path(slot: int) -> String:
	return "%s/slot_%d.json" % [SAVE_DIR, slot]


func slot_exists(slot: int) -> bool:
	return not read_slot(slot).is_empty()


## The parsed slot file, or {} when it is missing or unreadable (the .bak copy is tried before giving up).
func read_slot(slot: int) -> Dictionary:
	for path in [slot_path(slot), slot_path(slot) + ".bak"]:
		if not FileAccess.file_exists(path):
			continue
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and int(parsed.get("version", 0)) >= 1:
			return parsed
	return {}


## What the menu shows for a slot.
func slot_summary(slot: int) -> Dictionary:
	var data := read_slot(slot)
	if data.is_empty():
		return {"exists": false}
	var site: Dictionary = data.get("site", {})
	return {
		"exists": true,
		"stage": str(data.get("stage", "site_select")),
		"saved": float(data.get("saved", 0.0)),
		"playtime_s": float(data.get("playtime_s", 0.0)),
		"has_site": not site.is_empty(),
		"lon_deg": float(site.get("lon_deg", 0.0)),
		"lat_deg": float(site.get("lat_deg", 0.0)),
	}


## The slot that was saved most recently, or 0 when there is none.
func latest_slot() -> int:
	var best := 0
	var best_time := -1.0
	for slot in range(1, SLOT_COUNT + 1):
		var data := read_slot(slot)
		if data.is_empty():
			continue
		var t := float(data.get("saved", 0.0))
		if t > best_time:
			best_time = t
			best = slot
	return best


func delete_slot(slot: int) -> void:
	for path in [slot_path(slot), slot_path(slot) + ".bak", slot_path(slot) + ".tmp"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	if active and slot == current_slot:
		_end_session()


# ================================================================= sessions

func start_new_game(slot: int) -> void:
	current_slot = slot
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var now := Time.get_unix_time_from_system()
	_save = {
		"version": SAVE_VERSION,
		"slot": slot,
		"created": now,
		"saved": now,
		"playtime_s": 0.0,
		"seed": int(rng.randi()),
		"stage": "site_select",
		"inventory": {},
	}
	Inventory.reset()
	Repairs.reset()
	Life.reset()
	LandingSite.clear_site()
	active = true
	in_game = false
	save_now()
	_resume()


func continue_game(slot: int) -> bool:
	var data := read_slot(slot)
	if data.is_empty():
		return false
	current_slot = slot
	_save = data
	_heal_stage()
	Inventory.set_items(_save.get("inventory", {}))
	Repairs.set_state(_save.get("progress", {}))
	Life.set_state(_save.get("life", {}))
	LandingSite.clear_site()
	active = true
	in_game = false
	_resume()
	return true


# Earlier versions let the restore itself push a finished landing back to the "landing" stage (see
# _on_site_selected), so those slots replayed the crash cutscene. A slot that has crash data has landed.
func _heal_stage() -> void:
	if str(_save.get("stage", "")) == "landing" and not _save.get("crash", {}).is_empty():
		_save["stage"] = "playing"


func continue_latest() -> bool:
	var slot := latest_slot()
	return slot > 0 and continue_game(slot)


func _resume() -> void:
	match str(_save.get("stage", "site_select")):
		"landing":
			var site: Dictionary = _save.get("site", {})
			if site.is_empty():
				get_tree().change_scene_to_file(SITE_SELECT_SCENE)
				return
			_restoring = true
			LandingSite.set_site(float(site["lon_deg"]), float(site["lat_deg"]))
			_restoring = false
			get_tree().change_scene_to_file(LANDING_SCENE)
		"playing":
			_restore_landing_site()
			if str(_save.get("stage", "")) != "playing":      # the crash data was missing: start the stage over
				_resume()
				return
			_load_game_scene()
		_:
			get_tree().change_scene_to_file(SITE_SELECT_SCENE)


## Saves, ends the session and returns to the main menu.
func leave_to_menu() -> void:
	save_now()
	_end_session()
	get_tree().paused = false
	get_tree().change_scene_to_file(MENU_SCENE)


func quit_game() -> void:
	save_now()
	get_tree().quit()


func _end_session() -> void:
	LunarNav.end_session()
	active = false
	in_game = false
	current_slot = 0
	_save = {}
	_moon = null
	LandingSite.clear_site()


# ================================================================= saving

func save_now() -> void:
	if not active or current_slot <= 0:
		return
	_save["version"] = SAVE_VERSION
	_save["saved"] = Time.get_unix_time_from_system()
	_save["inventory"] = Inventory.get_items()
	_save["progress"] = Repairs.get_state()
	_save["life"] = Life.get_state()
	if LunarNav.active:
		_save["nav"] = LunarNav.get_state()
	if in_game:
		var state := _player_state()
		if not state.is_empty():
			_save["player"] = state
		_record_driven_vehicle()
		_record_inside_base()
	if _write_json(slot_path(current_slot), _save):
		saved.emit(current_slot)


func _write_json(path: String, data: Dictionary) -> bool:
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_error("GameState: could not write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(JSON.stringify(data, "\t", false, true))      # full precision: lon / lat need it
	file.close()
	# Keep the previous good save as .bak, then swap the new file in.
	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_error("GameState: could not finish saving %s (%s)" % [path, error_string(err)])
		return false
	return true


func _on_progress_changed() -> void:
	if in_game:
		save_now()


func _on_site_selected(lon_deg: float, lat_deg: float) -> void:
	if not active or _restoring:
		return
	if str(_save.get("stage", "")) == "playing":      # never move a finished landing back to the cutscene
		return
	_save["site"] = {"lon_deg": lon_deg, "lat_deg": lat_deg}
	_save["stage"] = "landing"
	save_now()


# ================================================================= entering the game scene

func _load_game_scene() -> void:
	_show_loading()
	_loading_path = GAME_SCENE
	ResourceLoader.load_threaded_request(GAME_SCENE)


func _poll_load() -> void:
	if _loading_path.is_empty():
		return
	match ResourceLoader.load_threaded_get_status(_loading_path):
		ResourceLoader.THREAD_LOAD_LOADED:
			var packed := ResourceLoader.load_threaded_get(_loading_path) as PackedScene
			_loading_path = ""
			get_tree().change_scene_to_packed(packed)
			get_tree().create_timer(30.0).timeout.connect(_hide_loading)      # failsafe if the scene never reports in
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("GameState: could not load %s" % _loading_path)
			_loading_path = ""
			_hide_loading()
			leave_to_menu()


func _show_loading() -> void:
	if _loading_layer != null:
		return
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 100
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_loading_layer.add_child(bg)
	var label := Label.new()
	label.text = "LOADING..."
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 26)
	_loading_layer.add_child(label)
	add_child(_loading_layer)


func _hide_loading() -> void:
	if _loading_layer != null:
		_loading_layer.queue_free()
		_loading_layer = null


# Runs when any node enters the tree; picks out the game planet (the root of moon_planet.scn) before its _ready.
# The landing cutscene's planet is a child of its scene, so it is skipped. LandingSite's own hook runs first
# (it connected first), so what is set here wins.
func _on_node_added(node: Node) -> void:
	if not active or not (node is MoonPlanet):
		return
	if node.get_parent() != get_tree().root:
		return
	var moon := node as MoonPlanet
	moon.place_default_rover = false                    # this class lays the world out itself
	var player_state: Dictionary = _save.get("player", {})
	if str(_save.get("stage", "")) == "playing" and not player_state.is_empty():
		moon.spawn_lon_deg = float(player_state["lon_deg"])
		moon.spawn_lat_deg = float(player_state["lat_deg"])
		moon.spawn_height_m = 1.0
	moon.ready.connect(_on_game_planet_ready.bind(moon), CONNECT_ONE_SHOT)


func _on_game_planet_ready(moon: MoonPlanet) -> void:
	_moon = moon
	in_game = true
	_autosave_t = 0.0
	_hide_loading()

	if str(_save.get("stage", "")) != "playing":        # first arrival after the crash: remember it
		_save["crash"] = _snapshot_crash()
		_save["stage"] = "playing"

	_restore_view(moon)
	_ground_player(moon)
	_build_world(moon)
	LunarNav.begin_session(_save, moon)
	_resume_driving(moon)
	_resume_inside(moon)
	save_now()


# Safety net for the spawn: whatever the cause, the player never starts more than a few metres above the exact ground.
func _ground_player(moon: MoonPlanet) -> void:
	if not (moon.player is MoonPlayer):
		return
	var h := moon.height_above_ground(moon.player)
	if h > SPAWN_MAX_HEIGHT_M:
		push_warning("GameState: spawned %.1f m above the ground, put on it" % h)
		moon.snap_to_ground(moon.player, 0.3)


# ================================================================= crash site

func _snapshot_crash() -> Dictionary:
	var debris: Array = []
	for d in LandingSite.wreck_debris:
		debris.append({"t": _t_to_arr(d["t"]), "size": _v_to_arr(d["size"])})
	return {
		"wreck_transform": _t_to_arr(LandingSite.wreck_transform),
		"wreck_model_scale": LandingSite.wreck_model_scale,
		"wreck_model_offset_y": LandingSite.wreck_model_offset_y,
		"wreck_half_height": LandingSite.wreck_half_height,
		"wreck_radius": LandingSite.wreck_radius,
		"wreck_debris": debris,
		"crater_lon_deg": LandingSite.crater_lon_deg,
		"crater_lat_deg": LandingSite.crater_lat_deg,
		"crater_radius_m": LandingSite.crater_radius_m,
		"spawn_lon_deg": LandingSite.spawn_lon_deg,
		"spawn_lat_deg": LandingSite.spawn_lat_deg,
	}


# Puts the saved landing site and crash back into the LandingSite autoload, which rebuilds the wreck.
func _restore_landing_site() -> void:
	var site: Dictionary = _save.get("site", {})
	var crash: Dictionary = _save.get("crash", {})
	if site.is_empty() or crash.is_empty():
		push_warning("GameState: slot %d has no crash data, going back to the landing sequence." % current_slot)
		_save["stage"] = "landing" if not site.is_empty() else "site_select"
		return
	_restoring = true                                  # set_site() emits site_selected; that must not touch the save
	LandingSite.set_site(float(site["lon_deg"]), float(site["lat_deg"]))
	_restoring = false
	LandingSite.wreck_transform = _arr_to_t(crash["wreck_transform"])
	LandingSite.wreck_model_scale = float(crash["wreck_model_scale"])
	LandingSite.wreck_model_offset_y = float(crash["wreck_model_offset_y"])
	LandingSite.wreck_half_height = float(crash["wreck_half_height"])
	LandingSite.wreck_radius = float(crash["wreck_radius"])
	var debris: Array = []
	for d in crash["wreck_debris"]:
		debris.append({"t": _arr_to_t(d["t"]), "size": _arr_to_v(d["size"])})
	LandingSite.wreck_debris = debris
	LandingSite.crater_lon_deg = float(crash["crater_lon_deg"])
	LandingSite.crater_lat_deg = float(crash["crater_lat_deg"])
	LandingSite.crater_radius_m = float(crash["crater_radius_m"])
	LandingSite.spawn_lon_deg = float(crash["spawn_lon_deg"])
	LandingSite.spawn_lat_deg = float(crash["spawn_lat_deg"])
	LandingSite.crashed = true


# ================================================================= player

func _player_state() -> Dictionary:
	if _moon == null or not is_instance_valid(_moon) or not (_moon.player is MoonPlayer):
		return {}
	var player := _moon.player as MoonPlayer
	var off: Array = _moon._off
	var gp := player.global_position
	var x: float = float(off[0]) + gp.x
	var y: float = float(off[1]) + gp.y
	var z: float = float(off[2]) + gp.z
	var r := sqrt(x * x + y * y + z * z)
	if r < 1.0:
		return {}
	var lon := atan2(x, z)
	var lat := asin(clampf(y / r, -1.0, 1.0))
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var north := Vector3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
	var fwd := -player.global_basis.z
	return {
		"lon_deg": rad_to_deg(lon),
		"lat_deg": rad_to_deg(lat),
		"heading": atan2(fwd.dot(north), fwd.dot(east)),        # radians from east, counter-clockwise toward north
		"pitch": float(player.get("_pitch")),
	}


# Turns the player to the saved heading and pitch (the position is applied through the planet's spawn point).
func _restore_view(moon: MoonPlanet) -> void:
	var state: Dictionary = _save.get("player", {})
	if state.is_empty() or not (moon.player is MoonPlayer):
		return
	var player := moon.player as MoonPlayer
	var lon := deg_to_rad(float(state["lon_deg"]))
	var lat := deg_to_rad(float(state["lat_deg"]))
	var up := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var north := Vector3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
	var h := float(state["heading"])
	var fwd := east * cos(h) + north * sin(h)
	player.global_basis = Basis.looking_at(fwd, up)
	var pitch := float(state.get("pitch", 0.0))
	player.set("_pitch", pitch)
	player.head.rotation.x = pitch


# ================================================================= placed objects

# Puts back every saved object, then places (and saves) any entry of WORLD_OBJECTS that the slot does not have yet.
# Saved entries that are no longer in WORLD_OBJECTS (like the standalone "Crafter" of an earlier version, which
# now lives inside interior_base.tscn) are dropped.
func _build_world(moon: MoonPlanet) -> void:
	var revs := {}
	for spec in WORLD_OBJECTS:
		revs[str(spec["id"])] = int(spec.get("rev", 1))
	var objects: Array = []
	var have := {}
	for o in _save.get("objects", []):
		var id := str(o["id"])
		if not revs.has(id):
			continue                                    # no longer in WORLD_OBJECTS
		if int(o.get("rev", 1)) < int(revs[id]):
			continue                                    # its placement rule changed: it is placed again below
		objects.append(o)
		have[id] = true
	_restore_objects(objects)
	for spec in WORLD_OBJECTS:
		if have.has(str(spec["id"])):
			continue
		var entry := _place_near(moon, spec, objects)
		if not entry.is_empty():
			objects.append(entry)
	_save["objects"] = objects


## Writes a placed object's current position back into the slot, so it stays where it was left (the lunar buggy
## calls this when the player climbs out). Objects that are not in the slot are ignored.
func record_object_pose(node: Node3D, save_after := true) -> void:
	if not active or _moon == null or not is_instance_valid(_moon):
		return
	var objects: Array = _save.get("objects", [])
	for o in objects:
		if str(o["id"]) != str(node.name):
			continue
		var pose := _pose_of(_moon, node, float(o.get("normal_sample_m", 2.0)))
		o["lon_deg"] = pose["lon_deg"]
		o["lat_deg"] = pose["lat_deg"]
		o["yaw_deg"] = pose["yaw_deg"]
		break
	if save_after:
		save_now()


# If the player is seated in a vehicle (the buggy), keep that vehicle's pose in the slot and remember that the
# player is in it, so a reload puts both back together.
func _record_driven_vehicle() -> void:
	_save.erase("driving")
	if _moon == null or not is_instance_valid(_moon) or not (_moon.player is MoonPlayer):
		return
	var vehicle: Node = (_moon.player as MoonPlayer).vehicle
	if vehicle is Node3D and is_instance_valid(vehicle):
		record_object_pose(vehicle as Node3D, false)
		_save["driving"] = str(vehicle.name)


# Seats the player in the vehicle they were driving when the slot was saved.
func _resume_driving(moon: MoonPlanet) -> void:
	var id := str(_save.get("driving", ""))
	if id.is_empty() or not (moon.player is MoonPlayer):
		return
	var vehicle := moon.get_node_or_null(id)
	if vehicle != null and vehicle.has_method("mount_player"):
		vehicle.call("mount_player", moon.player)


# Remembers whether the player is inside the lunar base, so a reload puts them back inside.
func _record_inside_base() -> void:
	_save.erase("inside")
	if _moon == null or not is_instance_valid(_moon):
		return
	var base := _moon.get_node_or_null("InteriorBase")
	if base != null and bool(base.get("player_inside")):
		_save["inside"] = true


func _resume_inside(moon: MoonPlanet) -> void:
	if not bool(_save.get("inside", false)):
		return
	var base := moon.get_node_or_null("InteriorBase")
	if base != null and base.has_method("enter_instantly"):
		base.call("enter_instantly", moon.player)


func _restore_objects(objects: Array) -> void:
	for o in objects:
		var inst := MoonPlanet.place_scene(str(o["scene"]), float(o["lon_deg"]), float(o["lat_deg"]),
			float(o["yaw_deg"]), 0.0, float(o["normal_sample_m"]))
		if inst == null:
			push_warning("GameState: could not restore %s" % o.get("id", "?"))
			continue
		inst.name = str(o["id"])


# One object, somewhere between spec.min and MAX_DISTANCE_M from the landing site: a flat patch if one can be
# found, otherwise a random spot. Returns the record that gets saved ({} on failure).
func _place_near(moon: MoonPlanet, spec: Dictionary, objects: Array) -> Dictionary:
	var node_name := str(spec["id"])
	var scene_path := str(spec["scene"])
	var footprint := float(spec["footprint"])
	var lon := LandingSite.lon_deg
	var lat := LandingSite.lat_deg
	var near_id := str(spec.get("near", ""))
	if near_id != "":
		var found := false
		for o in objects:
			if str(o["id"]) == near_id:
				lon = float(o["lon_deg"])
				lat = float(o["lat_deg"])
				found = true
				break
		if not found:
			push_warning("GameState: %s wants to be near %s, which is not placed; using the landing site." % [node_name, near_id])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(_save.get("seed", 1)) + node_name.hash()          # same slot + same id = same search, always

	var normal_sample := maxf(footprint, 0.5)              # what place_scene_flat uses for the tilt
	var max_m := float(spec.get("max", MAX_DISTANCE_M))
	var inst := MoonPlanet.place_scene_flat(scene_path, lon, lat, footprint, max_m, float(spec["min"]),
		float(spec["slope"]), float(spec["rough"]), FLAT_SEARCH_ATTEMPTS, true, 0.0, rng)
	if inst == null:
		normal_sample = 2.0                                # place_scene_random's default
		inst = MoonPlanet.place_scene_random(scene_path, lon, lat, max_m, true, 0.0, normal_sample, rng)
	if inst == null:
		push_warning("GameState: could not place %s" % node_name)
		return {}
	inst.name = node_name
	var pose := _pose_of(moon, inst, normal_sample)
	pose["id"] = node_name
	pose["scene"] = scene_path
	pose["rev"] = int(spec.get("rev", 1))
	print("GameState: %s placed %.0f m from %s (lon %.5f, lat %.5f)" % [
		node_name, _distance_m(moon, lon, lat, pose["lon_deg"], pose["lat_deg"]),
		near_id if near_id != "" else "the landing site", pose["lon_deg"], pose["lat_deg"]])
	return pose


# lon / lat / yaw of a node that place_scene_at() has just put on the ground (computed in doubles, so a
# placement 20 km away still reloads to within a millimetre or so).
func _pose_of(moon: MoonPlanet, node: Node3D, normal_sample_m: float) -> Dictionary:
	var off: Array = moon._off
	var gp := node.global_position
	var x: float = float(off[0]) + gp.x
	var y: float = float(off[1]) + gp.y
	var z: float = float(off[2]) + gp.z
	var r := sqrt(x * x + y * y + z * z)
	var lon := atan2(x, z)
	var lat := asin(clampf(y / r, -1.0, 1.0))
	# Undo place_scene_at's basis: Basis(normal, -yaw) * Basis(x_ref, normal, z). Yaw is the turn about the
	# normal between the reference x axis (east, flattened onto the ground) and the node's x axis.
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var normal := node.global_basis.y.normalized()
	var x_ref := (east - normal * east.dot(normal)).normalized()
	var turn := x_ref.signed_angle_to(node.global_basis.x.normalized(), normal)
	return {
		"lon_deg": rad_to_deg(lon),
		"lat_deg": rad_to_deg(lat),
		"yaw_deg": fposmod(-rad_to_deg(turn), 360.0),
		"normal_sample_m": normal_sample_m,
	}


# Ground distance in metres between two lon / lat points (chord form, which keeps its precision at small distances).
func _distance_m(moon: MoonPlanet, lon1: float, lat1: float, lon2: float, lat2: float) -> float:
	var a := _unit(lon1, lat1)
	var b := _unit(lon2, lat2)
	return moon.planet_radius_m * 2.0 * asin(minf((a - b).length() * 0.5, 1.0))


static func _unit(lon_deg: float, lat_deg: float) -> Vector3:
	var lon := deg_to_rad(lon_deg)
	var lat := deg_to_rad(lat_deg)
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


# ================================================================= JSON helpers

static func _v_to_arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func _arr_to_v(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _t_to_arr(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z,
		t.basis.y.x, t.basis.y.y, t.basis.y.z,
		t.basis.z.x, t.basis.z.y, t.basis.z.z,
		t.origin.x, t.origin.y, t.origin.z]


static func _arr_to_t(a: Array) -> Transform3D:
	return Transform3D(
		Basis(Vector3(float(a[0]), float(a[1]), float(a[2])),
			Vector3(float(a[3]), float(a[4]), float(a[5])),
			Vector3(float(a[6]), float(a[7]), float(a[8]))),
		Vector3(float(a[9]), float(a[10]), float(a[11])))
