extends WorldSite
## The propellant plant inside the lunar base. Once the base AND the solar array are repaired it makes fuel
## (Life.plant_fuel, a full 100 in about 7 minutes). E on it loads that fuel into the lunar buggy, which has to be
## parked within Life.LOAD_RANGE_M of the base; the buggy then carries it to the return spacecraft.
##
## The model is built from primitives here. The gauge shows how much fuel is in storage.

var _lamp_mat: StandardMaterial3D
var _gauge: MeshInstance3D
var _gauge_mat: StandardMaterial3D


func _init() -> void:
	label = "propellant plant"
	interact_radius = 3.5


func _ready() -> void:
	super._ready()
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.32, 0.35, 0.4)
	metal.metallic = 0.7
	metal.roughness = 0.5
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(0.2, 0.2, 0.2)
	_lamp_mat.emission = Color(0.3, 1.0, 0.45)
	_lamp_mat.emission_energy_multiplier = 2.0
	_gauge_mat = StandardMaterial3D.new()
	_gauge_mat.albedo_color = Color(1.0, 0.62, 0.2)
	_gauge_mat.emission_enabled = true
	_gauge_mat.emission = Color(1.0, 0.55, 0.15)
	_gauge_mat.emission_energy_multiplier = 1.5

	_box(Vector3(1.5, 1.7, 0.9), Vector3(0.0, 0.85, 0.0), metal)                      # cabinet
	_box(Vector3(1.0, 0.12, 0.05), Vector3(0.0, 1.45, 0.46), _lamp_mat)               # status lamp strip
	var tank := MeshInstance3D.new()                                                  # the gauge: a fuel column
	var cm := CylinderMesh.new()
	cm.top_radius = 0.22
	cm.bottom_radius = 0.22
	cm.height = 1.0
	tank.mesh = cm
	tank.material_override = _gauge_mat
	tank.position = Vector3(0.0, 0.2, 0.47)
	add_child(tank)
	_gauge = tank

	var body := StaticBody3D.new()                                                    # so it can be pointed at
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.5, 1.7, 0.9)
	shape.shape = box
	shape.position = Vector3(0.0, 0.85, 0.0)
	body.add_child(shape)
	add_child(body)


func _box(size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)


func _process(_delta: float) -> void:
	_lamp_mat.emission_enabled = Life.plant_powered()
	var f := clampf(Life.plant_fuel / Life.PLANT_CAPACITY, 0.0, 1.0)
	_gauge.visible = f > 0.01
	_gauge.scale = Vector3(1.0, maxf(f, 0.01) * 1.2, 1.0)
	_gauge.position.y = 0.2 + _gauge.scale.y * 0.5          # the column grows up from its base


func prompt_text() -> String:
	if not Life.plant_powered():
		return "Propellant plant: offline (finish the base and solar repairs)"
	var buggy := Life.find_buggy()
	if buggy != null and buggy.global_position.distance_to(global_position) <= Life.LOAD_RANGE_M and Life.cargo_capacity() > 0.0:
		return "Load fuel into the buggy (%d stored)" % int(round(Life.plant_fuel))
	return "Propellant plant: %d / %d stored" % [int(round(Life.plant_fuel)), int(Life.PLANT_CAPACITY)]


func interact(_player: Node) -> void:
	Dialogue.say(Life.load_buggy(global_position), 4.5, "Propellant plant")
