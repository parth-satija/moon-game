extends "res://scripts/moon_walk.gd"
## Landing cinematic: the Starship comes down on the landing site picked in landing_site_select.tscn,
## is struck by a meteor on final approach, falls, crashes and topples over, then the game scene loads.
##
## Builds on moon_walk.gd (sun, black sky, moon material). Everything of the ship is built in code and
## lives under an anchor that MoonPlanet.place_scene_at() tilts to the local ground normal, so the
## local frame is: +Y = up, +X = east, -Z = north. Units are metres, gravity is lunar.
##
## Skip with Space / Enter / Esc. When it ends, LandingSite.crashed is set and next_scene is loaded.

@export_file("*.tscn", "*.scn") var next_scene := "res://scenes/moon_planet.scn"
@export var ship_height_m := 50.0
@export var start_altitude_m := 320.0        # altitude of the ship's base when the shot starts
@export var hit_altitude_m := 95.0           # altitude of the ship's base when the meteor strikes
@export var camera_distance_m := 170.0
@export var camera_azimuth_deg := 215.0      # where the camera stands, measured around the pad (0 = south, 90 = east)
@export var crater_radius_m := 14.0

const SHIP_MODEL := "res://assets/starship_mk1/scene.gltf"
const MODEL_HEIGHT_UNITS := 215.45           # measured from the glTF mesh
const MODEL_BASE_Y := -79.52                 # model-space y of the ship's base
const MODEL_RADIUS_UNITS := 20.1
const GRAVITY := 1.62
const V_START := -38.0                       # descent speed at the start (m/s)
const V_HIT := -9.0                          # descent speed when the meteor hits
const METEOR_SPEED := 150.0
const METEOR_WINDOW := 3.2                   # seconds the meteor is visible before it hits

enum State { DESCENT, FALL, TOPPLE, SETTLED }

var _moon: MoonPlanet
var _site: Node3D                            # the anchor, aligned to the ground
var _cam: Camera3D
var _cam_pos := Vector3.ZERO
var _look_target := Vector3.ZERO
var _lon := 0.0
var _lat := 0.0

var _state := State.DESCENT
var _t := 0.0
var _state_t := 0.0
var _done := false
var _fading := false
var _fade_t := 0.0
var _shake := 0.0
var _flash_a := 0.0

var _half := 25.0
var _ship_radius := 4.7
var _pivot: Node3D
var _flame: MeshInstance3D
var _engine_light: OmniLight3D
var _vent: CPUParticles3D
var _fire_light: OmniLight3D
var _descent_T := 10.0
var _descent_a := 3.0
var _vel := Vector3.ZERO
var _omega_axis := Vector3.RIGHT
var _omega := 0.17
var _topple_omega := 0.17

var _meteor: Node3D
var _meteor_trail: CPUParticles3D
var _vdir := Vector3.DOWN
var _hit_point := Vector3.ZERO

var _debris: Array = []
var _debris_mat: StandardMaterial3D

var _black: ColorRect
var _flash: ColorRect
var _caption: Label
var _loading_label: Label
var _holder: Node3D
var _finishing := false                      # cutscene over, waiting for the next scene to finish loading
var _load_requested := false
var _crater_local := Vector3.ZERO


func _ready() -> void:
	_moon = get_node("MoonPlanet") as MoonPlanet
	# LandingSite already put the chosen spot into the planet's spawn_* (it runs when the planet enters the tree).
	_lon = _moon.spawn_lon_deg
	_lat = _moon.spawn_lat_deg

	# Low sun from behind-left of the camera, defined relative to the site (a fixed world sun could be below its horizon).
	var frame := _site_frame(_lon, _lat)
	var az_sun := deg_to_rad(camera_azimuth_deg - 40.0)
	var el_sun := deg_to_rad(24.0)
	sun_direction = (frame * Vector3(sin(az_sun) * cos(el_sun), sin(el_sun), cos(az_sun) * cos(el_sun))).normalized()

	super._ready()

	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.directional_shadow_max_distance = 700.0
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		we.environment.glow_enabled = true
		we.environment.glow_intensity = 0.6
		we.environment.glow_hdr_threshold = 1.0

	# moon.gd always drops the rover at lon 0.0005; it has no place in this shot.
	for c in _moon.get_children():
		if c.scene_file_path == "res://scenes/rover1.tscn":
			c.queue_free()

	_site = _moon.place_scene_at("res://scenes/landing_anchor.tscn", _lon, _lat, 0.0, 0.0, 20.0)
	_build_ui()
	if _site == null:
		push_warning("LandingSequence: could not place the landing anchor, skipping.")
		_finish()
		return

	_half = ship_height_m * 0.5
	_descent_T = 2.0 * (start_altitude_m - hit_altitude_m) / (absf(V_START) + absf(V_HIT))
	_descent_a = (V_HIT - V_START) / _descent_T

	_debris_mat = StandardMaterial3D.new()
	_debris_mat.albedo_color = Color(0.55, 0.56, 0.58)
	_debris_mat.metallic = 0.8
	_debris_mat.roughness = 0.5

	_build_ship()
	_build_meteor()
	_build_camera()
	_say("FINAL DESCENT   %s" % _fmt(_lon, _lat))
	_request_next_scene()                        # load the big planet scene in the background while this plays


# Local frame of a site: x = east, y = up, z = south (same as place_scene_at).
static func _site_frame(lon_deg: float, lat_deg: float) -> Basis:
	var lo := deg_to_rad(lon_deg)
	var la := deg_to_rad(lat_deg)
	var east := Vector3(cos(lo), 0.0, -sin(lo))
	var north := Vector3(-sin(la) * sin(lo), cos(la), -sin(la) * cos(lo))
	var up := Vector3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
	return Basis(east, up, -north)


static func _fmt(lon: float, lat: float) -> String:
	return "%.2f° %s, %.2f° %s" % [absf(lon), "E" if lon >= 0.0 else "W", absf(lat), "N" if lat >= 0.0 else "S"]


# ---------------------------------------------------------------- building

func _build_ship() -> void:
	var sc := ship_height_m / MODEL_HEIGHT_UNITS
	_ship_radius = MODEL_RADIUS_UNITS * sc

	_pivot = Node3D.new()
	_pivot.name = "ShipPivot"
	_site.add_child(_pivot)
	_pivot.position = Vector3(0.0, start_altitude_m + _half, 0.0)

	var holder := Node3D.new()
	_holder = holder
	_pivot.add_child(holder)
	var packed := load(SHIP_MODEL) as PackedScene
	if packed:
		holder.scale = Vector3.ONE * sc
		holder.position = Vector3(0.0, -_half - MODEL_BASE_Y * sc, 0.0)
		holder.add_child(packed.instantiate())
	else:
		push_warning("LandingSequence: could not load %s, using a placeholder hull." % SHIP_MODEL)
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = _ship_radius * 0.6
		cyl.bottom_radius = _ship_radius
		cyl.height = ship_height_m
		mi.mesh = cyl
		holder.add_child(mi)

	# Engine plume (a stretched additive cone) and the light it throws.
	_flame = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = _ship_radius * 0.7
	cone.bottom_radius = 0.3
	cone.height = 24.0
	cone.radial_segments = 20
	cone.rings = 1
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.albedo_color = Color(1.0, 0.55, 0.2, 0.55)
	fm.emission_enabled = true
	fm.emission = Color(1.0, 0.5, 0.18)
	fm.emission_energy_multiplier = 3.0
	cone.material = fm
	_flame.mesh = cone
	_flame.position = Vector3(0.0, -_half - 12.0, 0.0)
	_flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pivot.add_child(_flame)

	_engine_light = OmniLight3D.new()
	_engine_light.light_color = Color(1.0, 0.65, 0.35)
	_engine_light.light_energy = 6.0
	_engine_light.omni_range = 90.0
	_engine_light.position = Vector3(0.0, -_half - 4.0, 0.0)
	_pivot.add_child(_engine_light)

	# Where and from which direction the meteor arrives: steep, slightly sideways to the camera's view.
	var az := deg_to_rad(camera_azimuth_deg)
	var perp := Vector2(cos(az), -sin(az))
	_vdir = Vector3(perp.x * 0.28, -0.96, perp.y * 0.28).normalized()
	var hit_alt := hit_altitude_m + ship_height_m * 0.62
	_hit_point = Vector3(0.0, hit_alt, 0.0) - _vdir * _ship_radius


func _build_meteor() -> void:
	_meteor = Node3D.new()
	_meteor.name = "Meteor"
	_site.add_child(_meteor)
	_meteor.basis = Basis.looking_at(_vdir, Vector3.RIGHT)
	_meteor.visible = false

	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.5
	sm.height = 3.0
	sm.radial_segments = 12
	sm.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.18, 0.14)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.5, 0.15)
	mat.emission_energy_multiplier = 5.0
	sm.material = mat
	mi.mesh = sm
	mi.scale = Vector3(1.0, 0.9, 1.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_meteor.add_child(mi)

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.2)
	light.light_energy = 8.0
	light.omni_range = 120.0
	_meteor.add_child(light)

	var ramp := _ramp(PackedFloat32Array([0.0, 0.35, 1.0]),
		PackedColorArray([Color(1.0, 0.9, 0.6, 0.95), Color(1.0, 0.45, 0.12, 0.6), Color(0.3, 0.1, 0.05, 0.0)]))
	_meteor_trail = _new_particles(_meteor, Vector3.ZERO, 220, 1.2, ramp, true, 0.8)
	_meteor_trail.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_meteor_trail.emission_sphere_radius = 0.8
	_meteor_trail.initial_velocity_min = 0.0
	_meteor_trail.initial_velocity_max = 2.0
	_meteor_trail.gravity = Vector3.ZERO
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.1))
	_meteor_trail.scale_amount_curve = shrink


func _build_camera() -> void:
	_cam = get_node("Camera") as Camera3D
	var az := deg_to_rad(camera_azimuth_deg)
	var bearing := atan2(-cos(az), sin(az))          # radians, 0 = east, as _lonlat_offset expects
	var ll: Array = _moon._lonlat_offset(_lon, _lat, camera_distance_m, bearing)
	_cam_pos = _ground_world(float(ll[0]), float(ll[1]), 3.0)
	_cam.global_position = _cam_pos
	_look_target = _site.to_global(_pivot.position)
	_cam.look_at(_look_target, _site.global_basis.y)
	_cam.current = true


# Engine-frame position of the ground at a lon/lat, plus a height along the local up.
func _ground_world(lon_d: float, lat_d: float, height: float) -> Vector3:
	var lo := deg_to_rad(lon_d)
	var la := deg_to_rad(lat_d)
	var dir: Array = [cos(la) * sin(lo), sin(la), cos(la) * cos(lo)]
	var g: Array = _moon._ground_point(dir)
	var off: Array = _moon._off
	var up := Vector3(float(dir[0]), float(dir[1]), float(dir[2]))
	var p := Vector3(float(g[0]) - float(off[0]), float(g[1]) - float(off[1]), float(g[2]) - float(off[2]))
	return p + up * height


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)

	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.anchor_right = 1.0
		bar.anchor_top = 0.0 if top else 0.9
		bar.anchor_bottom = 0.1 if top else 1.0
		layer.add_child(bar)

	_caption = Label.new()
	_caption.anchor_right = 1.0
	_caption.anchor_top = 0.9
	_caption.anchor_bottom = 1.0
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_caption.add_theme_font_size_override("font_size", 22)
	_caption.add_theme_color_override("font_color", Color(0.9, 0.93, 1.0))
	layer.add_child(_caption)

	var skip := Label.new()
	skip.anchor_right = 1.0
	skip.anchor_bottom = 0.1
	skip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	skip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	skip.offset_right = -24.0
	skip.add_theme_font_size_override("font_size", 14)
	skip.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	skip.text = "Space: skip"
	layer.add_child(skip)

	_flash = ColorRect.new()
	_flash.color = Color(1, 1, 1, 0)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.anchor_right = 1.0
	_flash.anchor_bottom = 1.0
	layer.add_child(_flash)

	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 1)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_black.anchor_right = 1.0
	_black.anchor_bottom = 1.0
	layer.add_child(_black)

	_loading_label = Label.new()
	_loading_label.anchor_right = 1.0
	_loading_label.anchor_bottom = 1.0
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 26)
	_loading_label.text = "LOADING..."
	_loading_label.visible = false
	layer.add_child(_loading_label)


func _say(text: String) -> void:
	if _caption:
		_caption.text = text


# ---------------------------------------------------------------- main loop

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_cancel"):
		_finish()


func _process(delta: float) -> void:
	if _finishing:
		_poll_next_scene()
		return
	if _done or _site == null:
		return
	delta = minf(delta, 0.05)                    # the first frame includes the heavy mesh build
	_t += delta
	_state_t += delta

	match _state:
		State.DESCENT:
			_process_descent()
		State.FALL:
			_process_fall(delta)
		State.TOPPLE:
			_process_topple(delta)
		State.SETTLED:
			_process_settled()

	_update_meteor()
	_update_engine()
	_update_debris(delta)
	_update_camera(delta)
	_update_overlay(delta)


func _process_descent() -> void:
	var tt := minf(_t, _descent_T)
	var base_alt := start_altitude_m + V_START * tt + 0.5 * _descent_a * tt * tt
	_pivot.position = Vector3(0.0, base_alt + _half, 0.0)
	_pivot.rotation = Vector3(0.012 * sin(_t * 1.9 + 1.0), 0.0, 0.015 * sin(_t * 1.3))
	if _t >= _descent_T:
		_on_hit()


func _process_fall(delta: float) -> void:
	_vel.y -= GRAVITY * delta
	_pivot.position += _vel * delta
	_pivot.basis = (Basis(_omega_axis, _omega * delta) * _pivot.basis).orthonormalized()
	if _lowest_point() <= 0.0:
		_on_crash()


func _process_topple(delta: float) -> void:
	var cs := _pivot.basis.y.y
	if absf(cs) > 0.03:
		_topple_omega = minf(_topple_omega + 0.5 * delta, 0.9)
		var dir := 1.0 if cs > 0.0 else -1.0
		_pivot.basis = (Basis(_omega_axis, dir * _topple_omega * delta) * _pivot.basis).orthonormalized()
	_vel.x *= exp(-1.0 * delta)
	_vel.z *= exp(-1.0 * delta)
	_pivot.position.x += _vel.x * delta
	_pivot.position.z += _vel.z * delta
	var c := absf(_pivot.basis.y.y)
	var s := sqrt(maxf(0.0, 1.0 - c * c))
	_pivot.position.y = _half * c + _ship_radius * s
	if absf(_pivot.basis.y.y) <= 0.03 or _state_t > 6.0:
		_on_settled()


func _process_settled() -> void:
	if _fire_light:
		_fire_light.light_energy = 2.5 * (0.7 + 0.6 * randf())
	if _state_t > 1.4 and _caption.text != "SIGNAL LOST":
		_say("SIGNAL LOST")
	if _state_t > 5.0 and not _fading:
		_fading = true
	if _state_t > 7.0:
		_finish()


# ---------------------------------------------------------------- events

func _on_hit() -> void:
	_state = State.FALL
	_state_t = 0.0
	_say("MICROMETEOROID STRIKE")

	var hdir := Vector3(_vdir.x, 0.0, _vdir.z).normalized()
	_vel = hdir * 2.6 + Vector3(0.0, V_HIT, 0.0)
	_omega_axis = Vector3.UP.cross(hdir).normalized()    # tips the struck top away from the impact
	_omega = 0.17

	if _meteor:
		_meteor.queue_free()
		_meteor = null
		_meteor_trail = null

	_explosion(_hit_point, 1.0)
	_sparks(_hit_point, 70)
	_spawn_debris(_hit_point, 22, 6.0, 26.0)
	_flash_light(_hit_point, 60.0, Color(1.0, 0.75, 0.45), 200.0, 1.0)
	_flash_a = 0.85
	_shake = 1.0

	# Venting fire from the hole, stuck to the hull so it trails the falling ship.
	var ramp := _ramp(PackedFloat32Array([0.0, 0.4, 1.0]),
		PackedColorArray([Color(1.0, 0.85, 0.5, 0.9), Color(0.9, 0.4, 0.1, 0.6), Color(0.2, 0.15, 0.12, 0.0)]))
	var hole := _pivot.transform.affine_inverse() * _hit_point
	_vent = _new_particles(_pivot, hole, 70, 2.2, ramp, true, 0.7)
	_vent.direction = Vector3(-_vdir.x, 0.35, -_vdir.z).normalized()
	_vent.spread = 35.0
	_vent.initial_velocity_min = 5.0
	_vent.initial_velocity_max = 14.0
	_vent.scale_amount_min = 0.6
	_vent.scale_amount_max = 1.6
	_vent.gravity = _gravity_vec()
	_vent.emitting = true


func _on_crash() -> void:
	_state = State.TOPPLE
	_state_t = 0.0
	_say("CRASH LANDING")

	var axis := _pivot.basis.y
	var end := _pivot.position - axis * _half if axis.y >= 0.0 else _pivot.position + axis * _half
	var contact := Vector3(end.x, 0.0, end.z)

	_explosion(contact + Vector3(0.0, 2.0, 0.0), 1.6)
	_sparks(contact + Vector3(0.0, 2.0, 0.0), 90)
	_dust(contact)
	_spawn_debris(contact + Vector3(0.0, 3.0, 0.0), 28, 5.0, 30.0)
	_flash_light(contact + Vector3(0.0, 8.0, 0.0), 90.0, Color(1.0, 0.6, 0.3), 260.0, 1.6)
	_flash_a = 1.0
	_shake = 2.2
	_make_crater(contact)
	_crater_local = contact

	_topple_omega = _omega
	_vel.y = 0.0


func _on_settled() -> void:
	if _state == State.SETTLED:
		return
	_state = State.SETTLED
	_state_t = 0.0
	_explosion(_pivot.position, 1.0)
	_sparks(_pivot.position, 60)
	_flash_light(_pivot.position + Vector3(0.0, 6.0, 0.0), 40.0, Color(1.0, 0.6, 0.3), 160.0, 1.2)
	_flash_a = 0.35
	_shake = 1.0

	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Color(1.0, 0.5, 0.2)
	_fire_light.light_energy = 2.5
	_fire_light.omni_range = 70.0
	_pivot.add_child(_fire_light)


func _finish() -> void:
	if _done:
		return
	_done = true
	if _site != null:
		_record_crash()
	_request_next_scene()
	_black.color.a = 1.0
	_loading_label.visible = true
	_finishing = true


# Starts loading the next scene on a worker thread (it is ~120 MB; loading it in one go freezes the game).
func _request_next_scene() -> void:
	if _load_requested or next_scene == "":
		return
	_load_requested = true
	ResourceLoader.load_threaded_request(next_scene)


func _poll_next_scene() -> void:
	if next_scene == "":
		return
	match ResourceLoader.load_threaded_get_status(next_scene):
		ResourceLoader.THREAD_LOAD_LOADED:
			_finishing = false
			get_tree().change_scene_to_packed(ResourceLoader.load_threaded_get(next_scene) as PackedScene)
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_finishing = false
			get_tree().change_scene_to_file(next_scene)


# Hands the final state of the crash to the LandingSite autoload, which rebuilds it in the next scene.
func _record_crash() -> void:
	if _state == State.DESCENT or _state == State.FALL:      # skipped before the crash: lay the hull down where it would land
		var hdir := Vector3(_vdir.x, 0.0, _vdir.z).normalized()
		_omega_axis = Vector3.UP.cross(hdir).normalized()
		_pivot.basis = Basis(_omega_axis, PI * 0.5)
		_pivot.position = Vector3(hdir.x * 12.0, _ship_radius, hdir.z * 12.0)
		_crater_local = Vector3(_pivot.position.x, 0.0, _pivot.position.z)

	# Local (east, south) offsets -> lon/lat via moon.gd's bearing convention (0 = east, counter-clockwise).
	var wreck := Vector2(_pivot.position.x, _pivot.position.z)
	var wl: Array = _moon._lonlat_offset(_lon, _lat, wreck.length(), atan2(-wreck.y, wreck.x))
	var az := deg_to_rad(camera_azimuth_deg)
	var sp: Array = _moon._lonlat_offset(float(wl[0]), float(wl[1]), 45.0, atan2(-cos(az), sin(az)))
	var cr := Vector2(_crater_local.x, _crater_local.z)
	var cl: Array = _moon._lonlat_offset(_lon, _lat, cr.length(), atan2(-cr.y, cr.x))

	var list: Array = []
	for d in _debris:
		var n: MeshInstance3D = d["n"]
		var t := n.transform
		if not d["rest"]:
			t.origin.y = 0.3
		list.append({"t": t, "size": (n.mesh as BoxMesh).size})

	LandingSite.wreck_transform = _pivot.transform
	LandingSite.wreck_model_scale = _holder.scale.x
	LandingSite.wreck_model_offset_y = _holder.position.y
	LandingSite.wreck_half_height = _half
	LandingSite.wreck_radius = _ship_radius
	LandingSite.wreck_debris = list
	LandingSite.crater_lon_deg = float(cl[0])
	LandingSite.crater_lat_deg = float(cl[1])
	LandingSite.crater_radius_m = crater_radius_m
	LandingSite.spawn_lon_deg = float(sp[0])
	LandingSite.spawn_lat_deg = float(sp[1])
	LandingSite.crashed = true


# ---------------------------------------------------------------- per-frame helpers

# Height of the ship's lowest point above the local ground plane, modelling the hull as a cylinder.
func _lowest_point() -> float:
	var c := absf(_pivot.basis.y.y)
	var s := sqrt(maxf(0.0, 1.0 - c * c))
	return _pivot.position.y - _half * c - _ship_radius * s


func _update_meteor() -> void:
	if _meteor == null:
		return
	var tau := _descent_T - _t
	var show := _state == State.DESCENT and tau <= METEOR_WINDOW
	if show and not _meteor.visible:
		_meteor_trail.emitting = true
	_meteor.visible = show
	if show:
		_meteor.position = _hit_point - _vdir * METEOR_SPEED * tau


func _update_engine() -> void:
	if _flame == null:
		return
	if _state == State.DESCENT:
		_flame.visible = true
		_flame.scale = Vector3(1.0 + 0.1 * randf(), 1.0 + 0.25 * randf(), 1.0 + 0.1 * randf())
		_engine_light.light_energy = 6.0 * (0.85 + 0.3 * randf())
	elif _state == State.FALL and _state_t < 0.7:
		var on := randf() < 0.5                  # the engines sputter out
		_flame.visible = on
		_engine_light.light_energy = 6.0 if on else 0.0
	else:
		_flame.visible = false
		_engine_light.light_energy = 0.0


func _update_debris(delta: float) -> void:
	for d in _debris:
		if d["rest"]:
			continue
		var n: MeshInstance3D = d["n"]
		var v: Vector3 = d["v"]
		var w: Vector3 = d["w"]
		v.y -= GRAVITY * delta
		n.position += v * delta
		n.basis = (Basis(w.normalized(), w.length() * delta) * n.basis).orthonormalized()
		if n.position.y <= 0.3 and v.y < 0.0:
			n.position.y = 0.3
			d["rest"] = true
		d["v"] = v


func _update_camera(delta: float) -> void:
	var target := _site.to_global(_pivot.position)
	_look_target = _look_target.lerp(target, 1.0 - exp(-8.0 * delta))
	_cam.look_at(_look_target, _site.global_basis.y)
	_shake = move_toward(_shake, 0.0, delta * 0.9)
	_cam.h_offset = randf_range(-1.0, 1.0) * _shake * 0.35
	_cam.v_offset = randf_range(-1.0, 1.0) * _shake * 0.35


func _update_overlay(delta: float) -> void:
	_flash_a = move_toward(_flash_a, 0.0, delta * 1.1)
	_flash.color.a = _flash_a
	if _fading:
		_fade_t += delta
		_black.color.a = clampf(_fade_t / 1.6, 0.0, 1.0)
	else:
		_black.color.a = clampf(1.0 - (_t - 0.25) / 1.6, 0.0, 1.0)


# ---------------------------------------------------------------- effects

func _gravity_vec() -> Vector3:
	return -_site.global_basis.y * GRAVITY


func _ramp(offsets: PackedFloat32Array, colors: PackedColorArray) -> Gradient:
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	return g


func _new_particles(parent: Node3D, pos: Vector3, amount: int, life: float, ramp: Gradient, additive: bool, radius: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		mat.roughness = 1.0
	sm.material = mat
	p.mesh = sm
	p.amount = amount
	p.lifetime = life
	p.color_ramp = ramp
	p.local_coords = false
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(p)
	p.position = pos
	return p


func _free_later(n: Node, seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(n.queue_free)


func _explosion(pos: Vector3, k: float) -> void:
	var ramp := _ramp(PackedFloat32Array([0.0, 0.2, 0.55, 1.0]),
		PackedColorArray([Color(1.0, 0.95, 0.75, 1.0), Color(1.0, 0.55, 0.15, 0.9), Color(0.3, 0.1, 0.05, 0.45), Color(0.05, 0.05, 0.05, 0.0)]))
	var p := _new_particles(_site, pos, int(90.0 * k), 1.8, ramp, true, 1.0)
	p.one_shot = true
	p.explosiveness = 1.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 2.0 * k
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 5.0 * k
	p.initial_velocity_max = 26.0 * k
	p.scale_amount_min = 1.5 * k
	p.scale_amount_max = 4.5 * k
	p.gravity = _gravity_vec()
	p.emitting = true
	_free_later(p, 5.0)


func _sparks(pos: Vector3, amount: int) -> void:
	var ramp := _ramp(PackedFloat32Array([0.0, 0.5, 1.0]),
		PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.55, 0.15, 0.8), Color(0.4, 0.1, 0.02, 0.0)]))
	var p := _new_particles(_site, pos, amount, 3.0, ramp, true, 0.15)
	p.one_shot = true
	p.explosiveness = 0.95
	p.direction = Vector3.UP
	p.spread = 180.0
	p.initial_velocity_min = 12.0
	p.initial_velocity_max = 55.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	p.gravity = _gravity_vec()
	p.emitting = true
	_free_later(p, 5.0)


# Regolith thrown up by the crash: lit grey grains on ballistic arcs (no air to slow or lift them).
func _dust(pos: Vector3) -> void:
	var ramp := _ramp(PackedFloat32Array([0.0, 0.5, 1.0]),
		PackedColorArray([Color(0.72, 0.70, 0.66, 0.8), Color(0.62, 0.60, 0.57, 0.55), Color(0.5, 0.48, 0.46, 0.0)]))
	var p := _new_particles(_site, pos, 240, 9.0, ramp, false, 1.0)
	p.one_shot = true
	p.explosiveness = 0.9
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 5.0
	p.direction = Vector3.UP
	p.spread = 80.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 30.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 2.4
	p.gravity = _gravity_vec()
	p.emitting = true
	_free_later(p, 11.0)


func _spawn_debris(origin: Vector3, count: int, v_min: float, v_max: float) -> void:
	for i in count:
		var m := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(randf_range(0.5, 2.6), randf_range(0.2, 1.4), randf_range(0.5, 2.2))
		m.mesh = bm
		m.material_override = _debris_mat
		_site.add_child(m)
		m.position = origin + Vector3(randf_range(-1.5, 1.5), randf_range(-1.0, 1.0), randf_range(-1.5, 1.5))
		var dir := Vector3(randf_range(-1.0, 1.0), randf_range(-0.15, 1.0), randf_range(-1.0, 1.0)).normalized()
		var spin := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)).normalized()
		_debris.append({
			"n": m,
			"v": dir * randf_range(v_min, v_max),
			"w": spin * randf_range(1.0, 5.0),
			"rest": false,
		})


func _flash_light(pos: Vector3, energy: float, color: Color, range_m: float, duration: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = range_m
	_site.add_child(l)
	l.position = pos
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, duration)
	tw.tween_callback(l.queue_free)


# Carves a shallow crater into the planet where the ship struck (persists in mesh and collision).
func _make_crater(local_pos: Vector3) -> void:
	var dist := Vector2(local_pos.x, local_pos.z).length()
	var bearing := atan2(-local_pos.z, local_pos.x)
	var ll: Array = _moon._lonlat_offset(_lon, _lat, dist, bearing)
	_moon.add_impact_crater(float(ll[0]), float(ll[1]), crater_radius_m, 0.12, 0.25)
