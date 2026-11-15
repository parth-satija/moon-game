extends Node
## Autoload "LandingSite": holds the landing spot picked in landing_site_select.tscn and, after the
## landing cutscene, the crashed starship so any MoonPlanet scene can show it.
##
## Read it from anywhere:
##     LandingSite.lon_deg, LandingSite.lat_deg, LandingSite.has_selection, LandingSite.crashed
##     LandingSite.site_selected.connect(func(lon, lat): ...)
##
## It applies everything automatically: any MoonPlanet (moon.gd) that enters the tree after a selection
## gets its spawn_lon_deg / spawn_lat_deg set before its _ready builds the first mesh. After a crash the
## player spawns next to the wreck, and once the planet is ready the wreck, its debris and the crater
## are placed on the ground at the landing site.
## Longitude is east-positive (-90..90 on the near side), latitude north-positive, same convention as moon.gd.
##
## THE HULL CAN BE LIFTED
## The lunar buggy (lrv.gd) has a winch that raises the crashed hull LIFT_HEIGHT_M on jack stands, which opens
## its underside as a salvage site (wreck_underside.gd). The pieces live here because this script builds the wreck:
##     LandingSite.has_wreck()                  the hull exists in the loaded scene
##     LandingSite.distance_to_wreck(world_pos) metres from a point to the hull's surface
##     LandingSite.begin_wreck_lift(from_pos)   puts a lug on the hull side facing from_pos and returns it
##     LandingSite.set_wreck_lift(0..1)         raises the hull (and grows the stands under it)
##     LandingSite.finish_wreck_lift()          sets it to fully raised, saves the flag, opens the underside
##     LandingSite.is_wreck_lifted()            the "wreck_lifted" flag in Repairs (saved with the slot)
## A lifted hull is rebuilt raised, on its stands, every time the crash site is loaded.

signal site_selected(lon_deg: float, lat_deg: float)

const SHIP_MODEL := "res://assets/starship_mk1/scene.gltf"
const ANCHOR_SCENE := "res://scenes/landing_anchor.tscn"
const UNDERSIDE_SCRIPT := "res://scripts/wreck_underside.gd"

const LIFT_HEIGHT_M := 3.0
const LIFT_JACK_OFFSETS := [-14.0, 0.0, 14.0]       # where the stands go along the hull axis (metres from its centre)
const LIFT_JACK_SINK_M := 2.0                       # how far the stands reach into the ground

var has_selection := false
var lon_deg := 0.0
var lat_deg := 0.0

# --- filled in by landing_sequence.gd when the ship has crashed ---
var crashed := false
var wreck_transform := Transform3D.IDENTITY        # hull centre, relative to the landing anchor (+Y up, +X east, -Z north)
var wreck_model_scale := 1.0
var wreck_model_offset_y := 0.0                    # model holder offset inside the hull node
var wreck_half_height := 25.0
var wreck_radius := 4.7
var wreck_debris: Array = []                       # [{"t": Transform3D, "size": Vector3}], relative to the anchor
var crater_lon_deg := 0.0
var crater_lat_deg := 0.0
var crater_radius_m := 14.0
var spawn_lon_deg := 0.0                           # where the player stands after the crash (next to the wreck)
var spawn_lat_deg := 0.0

# --- the wreck as built in the loaded game scene (see _populate) ---
var wreck_pivot: Node3D                            # the hull; wreck_transform is its transform inside wreck_anchor
var wreck_anchor: Node3D
var _underside: Node3D
var _lug: Node3D
var _jacks: Array = []                             # [{"node": MeshInstance3D, "x": float, "z": float, "y0": float}]
var _lift_progress := 0.0


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func set_site(lon: float, lat: float) -> void:
	lon_deg = lon
	lat_deg = lat
	has_selection = true
	crashed = false
	wreck_debris = []
	site_selected.emit(lon, lat)


func clear_site() -> void:
	has_selection = false
	crashed = false
	wreck_debris = []
	wreck_pivot = null
	wreck_anchor = null
	_underside = null
	_lug = null
	_jacks.clear()


func _on_node_added(node: Node) -> void:
	if not (has_selection and node is MoonPlanet):
		return
	var moon := node as MoonPlanet
	if crashed:
		moon.spawn_lon_deg = spawn_lon_deg
		moon.spawn_lat_deg = spawn_lat_deg
		moon.ready.connect(_populate.bind(moon), CONNECT_ONE_SHOT)
	else:
		moon.spawn_lon_deg = lon_deg
		moon.spawn_lat_deg = lat_deg


# Rebuilds the crash site in a freshly loaded planet: hull (with collision), debris and crater.
func _populate(moon: MoonPlanet) -> void:
	var anchor := moon.place_scene_at(ANCHOR_SCENE, lon_deg, lat_deg, 0.0, 0.0, 20.0)
	if anchor == null:
		return
	anchor.name = "CrashedStarship"

	var pivot := Node3D.new()
	anchor.add_child(pivot)
	pivot.transform = wreck_transform
	wreck_anchor = anchor
	wreck_pivot = pivot
	_lift_progress = 0.0
	_lug = null

	var holder := Node3D.new()
	pivot.add_child(holder)
	var packed := load(SHIP_MODEL) as PackedScene
	if packed:
		holder.scale = Vector3.ONE * wreck_model_scale
		holder.position = Vector3(0.0, wreck_model_offset_y, 0.0)
		holder.add_child(packed.instantiate())
	else:
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = wreck_radius * 0.6
		cyl.bottom_radius = wreck_radius
		cyl.height = wreck_half_height * 2.0
		mi.mesh = cyl
		holder.add_child(mi)

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var cyl_shape := CylinderShape3D.new()
	cyl_shape.radius = wreck_radius
	cyl_shape.height = wreck_half_height * 2.0
	shape.shape = cyl_shape
	body.add_child(shape)
	# The hull is a salvage site: the player's interact ray hits `body` and walks up to this node.
	var src := WorldSite.new()
	src.label = "crashed Starship"
	src.salvage = true
	src.salvage_id = "wreck"
	src.interact_radius = 8.0
	pivot.add_child(src)
	src.add_child(body)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.56, 0.58)
	mat.metallic = 0.8
	mat.roughness = 0.5
	for d in wreck_debris:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = d["size"]
		m.mesh = bm
		m.material_override = mat
		anchor.add_child(m)
		m.transform = d["t"]

	_build_jacks()
	_build_underside()
	if is_wreck_lifted():                                    # lifted in an earlier session: put it back raised
		set_wreck_lift(1.0)
		if is_instance_valid(_underside):
			_underside.call("activate")

	moon.add_impact_crater(crater_lon_deg, crater_lat_deg, crater_radius_m, 0.12, 0.25)


# ================================================================= lifting the hull

func is_wreck_lifted() -> bool:
	return Repairs.has_flag(Repairs.FLAG_WRECK_LIFTED)


func has_wreck() -> bool:
	return crashed and is_instance_valid(wreck_pivot)


## Metres from a world position to the hull's surface (0 when touching it). INF when there is no wreck.
func distance_to_wreck(world_pos: Vector3) -> float:
	if not has_wreck():
		return INF
	var axis := wreck_pivot.global_basis.y.normalized()
	var centre := wreck_pivot.global_position
	var t := clampf((world_pos - centre).dot(axis), -wreck_half_height, wreck_half_height)
	return maxf(world_pos.distance_to(centre + axis * t) - wreck_radius, 0.0)


## Puts a lug on the hull, on the side facing from_world and a little way up it, and returns it. The winch
## cable ends at the lug, which is part of the hull and so rises with it. Null when there is no wreck.
func begin_wreck_lift(from_world: Vector3) -> Node3D:
	if not has_wreck():
		return null
	if is_instance_valid(_lug):
		_lug.queue_free()
	var axis := wreck_pivot.global_basis.y.normalized()
	var centre := wreck_pivot.global_position
	var t := clampf((from_world - centre).dot(axis), -wreck_half_height * 0.8, wreck_half_height * 0.8)
	var on_axis := centre + axis * t
	var toward := from_world - on_axis
	toward -= axis * toward.dot(axis)
	if toward.length_squared() < 1e-4:
		toward = axis.cross(Vector3.UP)
	toward = toward.normalized()
	var up := wreck_anchor.global_basis.y.normalized()
	var lift := up - axis * up.dot(axis)
	lift = lift.normalized() if lift.length_squared() > 1e-4 else toward.cross(axis).normalized()
	var dir := (toward * cos(deg_to_rad(35.0)) + lift * sin(deg_to_rad(35.0))).normalized()

	_lug = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.6, 0.6, 0.6)
	var lug_mesh := _lug as MeshInstance3D
	lug_mesh.mesh = bm
	var lug_mat := StandardMaterial3D.new()
	lug_mat.albedo_color = Color(0.95, 0.5, 0.1)
	lug_mat.metallic = 0.3
	lug_mat.roughness = 0.6
	lug_mesh.material_override = lug_mat
	wreck_pivot.add_child(_lug)
	_lug.global_position = on_axis + dir * wreck_radius
	return _lug


## Raises the hull to progress (0 = lying on the ground, 1 = LIFT_HEIGHT_M up on its stands).
func set_wreck_lift(progress: float) -> void:
	_lift_progress = clampf(progress, 0.0, 1.0)
	if not has_wreck():
		return
	var base := wreck_transform.origin
	wreck_pivot.position = Vector3(base.x, base.y + LIFT_HEIGHT_M * _lift_progress, base.z)
	for j in _jacks:
		var m := j["node"] as MeshInstance3D
		if not is_instance_valid(m):
			continue
		var top := float(j["y0"]) + LIFT_HEIGHT_M * _lift_progress
		var bottom := float(j["y0"]) - LIFT_JACK_SINK_M
		m.visible = _lift_progress > 0.0
		m.scale = Vector3(1.0, top - bottom, 1.0)
		m.position = Vector3(float(j["x"]), (top + bottom) * 0.5, float(j["z"]))


## The lift is done: hull fully raised, the flag saved with the slot, the underside open.
func finish_wreck_lift() -> void:
	set_wreck_lift(1.0)
	Repairs.set_flag(Repairs.FLAG_WRECK_LIFTED)
	if is_instance_valid(_underside):
		_underside.call("activate")


# Direction (anchor space) from the hull's axis to its lowest point, or ZERO when the hull stands on end.
func _belly_dir() -> Vector3:
	var axis := wreck_transform.basis.y.normalized()
	var perp := Vector3.DOWN - axis * axis.dot(Vector3.DOWN)
	return perp.normalized() if perp.length() > 0.25 else Vector3.ZERO


# Three stands under the hull's belly. They are built hidden and grow as the hull rises.
func _build_jacks() -> void:
	_jacks.clear()
	var dir := _belly_dir()
	if dir == Vector3.ZERO:
		return
	var axis := wreck_transform.basis.y.normalized()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.55, 0.1)
	mat.metallic = 0.5
	mat.roughness = 0.6
	for s in LIFT_JACK_OFFSETS:
		var belly := wreck_transform.origin + axis * float(s) + dir * wreck_radius
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.4
		cyl.bottom_radius = 0.55
		cyl.height = 1.0
		m.mesh = cyl
		m.material_override = mat
		m.visible = false
		wreck_anchor.add_child(m)
		_jacks.append({"node": m, "x": belly.x, "z": belly.z, "y0": belly.y})


# The underside salvage site, parented to the hull so it rises with it; it only opens once the hull is lifted.
func _build_underside() -> void:
	var script := load(UNDERSIDE_SCRIPT) as GDScript
	if script == null:
		push_warning("LandingSite: could not load %s" % UNDERSIDE_SCRIPT)
		return
	_underside = script.new() as Node3D
	wreck_pivot.add_child(_underside)
	var dir := _belly_dir()
	if dir != Vector3.ZERO:
		_underside.position = wreck_transform.basis.inverse() * (dir * wreck_radius)
