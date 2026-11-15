extends Node3D
## Playable moon scene: sun, black star sky, the spherical moon and the first-person Player.
##
## The moon's material is built here at runtime (instead of being stored in the .tscn) because
## moon.gd pushes the 8192x4096 heightmap texture into the material as a shader parameter; if that
## material were a saved sub-resource, the scene file would balloon to hundreds of MB.

@export var sun_direction := Vector3(0.8, 0.25, 0.45)    # world-space direction TOWARD the sun
@export var sun_energy := 1.0
@export var moon_shader_path := "res://scenes/moon_material.gdshader"
@export var moon_texture_path := "res://moon_color_preview.png"
@export var sky_shader_path := "res://scenes/star_sky.gdshader"


func _enter_tree() -> void:
	# Runs before the children's _ready, so moon.gd sees the material when it builds the mesh.
	var moon := get_node_or_null("MoonPlanet") as MoonPlanet
	if moon == null or moon.material != null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = load(moon_shader_path) as Shader
	var tex := load(moon_texture_path) as Texture2D
	if tex:
		mat.set_shader_parameter("moon_tex", tex)
	mat.set_shader_parameter("use_vertex_color", 0.0)
	moon.material = mat


func _ready() -> void:
	var dir := sun_direction.normalized()

	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		var hint := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
		sun.transform = Transform3D(Basis.looking_at(-dir, hint), Vector3.ZERO)
		sun.light_energy = sun_energy
		sun.shadow_enabled = true
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 300.0

	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we:
		var sky_mat := ShaderMaterial.new()
		sky_mat.shader = load(sky_shader_path) as Shader
		sky_mat.set_shader_parameter("sun_dir", dir)
		var sky := Sky.new()
		sky.sky_material = sky_mat
		var env := Environment.new()
		env.background_mode = Environment.BG_SKY
		env.sky = sky
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR   # no atmosphere: shadows stay near black
		env.ambient_light_color = Color(0.03, 0.03, 0.035)
		env.ambient_light_energy = 1.0
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		we.environment = env
