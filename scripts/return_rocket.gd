extends WorldSite
## The return spacecraft: the Starship, standing on its pad. It uses the same model and scale as the ship in the
## orbital docking sequence (orbital_docking.gd), whose constants are repeated below.
##
## What E does depends on how far along the spacecraft is:
##     repairs unfinished      tells you what is left (they are made at the crafter in the base)
##     tank not full           transfers the fuel the buggy carries (Life.unload_to_rocket)
##     repaired and fuelled    boards and launches: fades out and hands over to the orbital docking scene,
##                             which is the ascent, rendezvous and docking that ends the game
## After a successful dock the Repairs flag "mission_complete" is set (Life.complete_mission) and the pad is empty.
##
## Once its power system is repaired the spacecraft also refills the suit's oxygen within OXYGEN_RANGE_M
## (it is in the "oxygen_station" group, see life.gd).

const SHIP_MODEL := "res://assets/starship_mk1/scene.gltf"
const MODEL_HEIGHT_UNITS := 215.45        # same values as orbital_docking.gd
const MODEL_BASE_Y := -79.52
const SHIP_LEN := 50.0
const HULL_R := 4.6
const OXYGEN_RANGE_M := 14.0
const OXYGEN_RATE := 1.0 / 30.0           # fraction of a full tank per second
const FADE_S := 1.2

enum Status { GONE, REPAIRS, FUEL, READY }

var _body: StaticBody3D
var _busy := false


func _init() -> void:
	label = "return spacecraft"
	interact_radius = 14.0


func _ready() -> void:
	super._ready()
	_build_model()
	if status() == Status.GONE:
		_remove_from_pad()
	else:
		add_to_group("oxygen_station")


func status() -> Status:
	if Repairs.has_flag(Life.FLAG_MISSION_COMPLETE):
		return Status.GONE
	if not Repairs.stage_complete("rocket"):
		return Status.REPAIRS
	if Life.rocket_fuel < Life.ROCKET_TANK - 0.01:
		return Status.FUEL
	return Status.READY


# The Starship model, standing on its tail with the base of the model on the ground.
func _build_model() -> void:
	var sc := SHIP_LEN / MODEL_HEIGHT_UNITS
	var holder := Node3D.new()
	add_child(holder)
	var packed := load(SHIP_MODEL) as PackedScene
	if packed:
		holder.scale = Vector3.ONE * sc
		holder.position = Vector3(0.0, -MODEL_BASE_Y * sc, 0.0)
		holder.add_child(packed.instantiate())
	else:
		push_warning("ReturnRocket: could not load %s, using a placeholder hull." % SHIP_MODEL)
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = HULL_R * 0.5
		cyl.bottom_radius = HULL_R
		cyl.height = SHIP_LEN
		mi.mesh = cyl
		mi.position = Vector3(0.0, SHIP_LEN * 0.5, 0.0)
		holder.add_child(mi)

	# A solid hull, so the player can walk up to it, point at it and be stopped by it.
	_body = StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var cyl_shape := CylinderShape3D.new()
	cyl_shape.radius = HULL_R
	cyl_shape.height = SHIP_LEN
	shape.shape = cyl_shape
	shape.position = Vector3(0.0, SHIP_LEN * 0.5, 0.0)
	_body.add_child(shape)
	add_child(_body)


func _remove_from_pad() -> void:
	visible = false
	if _body != null:
		_body.collision_layer = 0
	remove_from_group("interactible")


# ================================================================= oxygen

## A powered spacecraft refills the suit next to it (Life polls every "oxygen_station").
func oxygen_rate_at(pos: Vector3) -> float:
	if status() == Status.GONE or not Repairs.is_done("rocket_power"):
		return 0.0
	return OXYGEN_RATE if pos.distance_to(global_position) <= OXYGEN_RANGE_M else 0.0


# ================================================================= interaction

func prompt_text() -> String:
	match status():
		Status.REPAIRS:
			var p := Repairs.stage_progress("rocket")
			return "Inspect the spacecraft (%d of %d repairs left)" % [p.y - p.x, p.y]
		Status.FUEL:
			var buggy := Life.find_buggy()
			if Life.buggy_cargo >= 1.0 and buggy != null and buggy.global_position.distance_to(global_position) <= Life.UNLOAD_RANGE_M:
				return "Transfer fuel from the buggy (%d)" % int(round(Life.buggy_cargo))
			return "Spacecraft fuel tank: %d%%" % int(round(Life.rocket_fuel / Life.ROCKET_TANK * 100.0))
		Status.READY:
			return "Board and launch"
	return ""


func interact(_player: Node) -> void:
	if _busy:
		return
	match status():
		Status.REPAIRS:
			var p := Repairs.stage_progress("rocket")
			Dialogue.say("The spacecraft is not flight-ready: %d of %d repairs remain. Build them at the crafter in the base." % [p.y - p.x, p.y], 5.0, "Suit computer")
		Status.FUEL:
			Dialogue.say(Life.unload_to_rocket(global_position), 5.5, "Spacecraft")
		Status.READY:
			_launch()


# Fade out, then hand over to the orbital docking scene (GameState saves first).
func _launch() -> void:
	_busy = true
	Dialogue.say("Boarding. Starting the launch sequence.", 3.0, "Astronaut")
	var player := get_tree().get_first_node_in_group("player") as MoonPlayer
	if player != null:
		player.set_physics_process(false)
	Life.suspended = true

	var layer := CanvasLayer.new()
	layer.layer = 60
	var rect := ColorRect.new()
	rect.color = Color(0, 0, 0, 0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	add_child(layer)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 1.0, FADE_S)
	tw.tween_callback(GameState.launch_to_docking)
