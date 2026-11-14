@tool
class_name LunarEnvironment
extends Node3D
## Realistic lunar environment: black airless sky, true-size sun, a phased Earth, stars + Milky Way,
## hard sun shadows, earthshine and regolith-bounce fill light.
##
## USAGE: instance res://scenes/lunar_environment.tscn as a child of the MoonPlanet root in
## moon_planet.scn (or anywhere in the scene). Leave it at the origin, unrotated: the sky and lights
## live in WORLD space, which for this project is also planet space (the floating origin only
## translates). Remove any other WorldEnvironment / sun DirectionalLight3D, since a scene can only use
## one WorldEnvironment.
##
## The sun and Earth are placed in the PLANET frame with the same lon/lat convention as moon.gd:
## direction = (cos(lat) sin(lon), sin(lat), cos(lat) cos(lon)). The sun's elevation therefore
## changes correctly as the player walks around the globe. Earth is tidally locked, so it stays near
## (lon 0, lat 0): straight overhead at the default spawn, lower toward the limb, never visible from
## the far side.
##
## Eclipse tip: set subsolar longitude 0 and latitude 0 and the Earth covers the sun; the light dims
## and reddens and a red ring appears around the Earth.

const SYNODIC_DAYS := 29.53

# Runtime state (the exported values are only the starting point).
var _sun_lon := 70.0
var _earth_rot := 0.0
var _search_cd := 0.0
var _sun: DirectionalLight3D
var _earthlight: DirectionalLight3D
var _env: Environment
var _sky_mat: ShaderMaterial

@export_group("Sun")
## Longitude of the point on the Moon where the sun is directly overhead.
@export_range(-180.0, 180.0, 0.1, "degrees") var subsolar_longitude_deg := 70.0:
	set(v):
		subsolar_longitude_deg = v
		_sun_lon = v
		_refresh()
## The real Moon's axial tilt keeps this within about +-1.5 degrees.
@export_range(-90.0, 90.0, 0.1, "degrees") var subsolar_latitude_deg := 1.5:
	set(v):
		subsolar_latitude_deg = v
		_refresh()
@export_range(0.0, 4.0, 0.01) var sun_energy := 1.0:
	set(v):
		sun_energy = v
		_refresh()
@export var sun_color := Color(1.0, 0.98, 0.94):
	set(v):
		sun_color = v
		_refresh()
## True value is 0.53. Larger values give softer shadow edges and a bigger disc.
@export_range(0.1, 5.0, 0.01) var sun_angular_diameter_deg := 0.53:
	set(v):
		sun_angular_diameter_deg = v
		_refresh()
@export var sun_shadows := true:
	set(v):
		sun_shadows = v
		_refresh()

@export_group("Day Cycle")
## Runtime only. The sun crosses the sky east to west over one lunar day.
@export var day_cycle_enabled := false
## Real seconds per full lunar day (29.5 Earth days). 1800 = a 30 minute day.
@export_range(30.0, 36000.0, 1.0, "or_greater") var lunar_day_seconds := 1800.0

@export_group("Earth")
@export var earth_enabled := true:
	set(v):
		earth_enabled = v
		_refresh()
## Sub-Earth point. Libration moves it a few degrees around (0, 0).
@export_range(-30.0, 30.0, 0.1, "degrees") var earth_longitude_deg := 0.0:
	set(v):
		earth_longitude_deg = v
		_refresh()
@export_range(-30.0, 30.0, 0.1, "degrees") var earth_latitude_deg := 0.0:
	set(v):
		earth_latitude_deg = v
		_refresh()
## True value is 1.9 degrees (about 3.7x the sun's width).
@export_range(0.5, 10.0, 0.01) var earth_angular_diameter_deg := 1.9:
	set(v):
		earth_angular_diameter_deg = v
		_refresh()
@export_range(0.0, 8.0, 0.01) var earth_brightness := 1.6:
	set(v):
		earth_brightness = v
		_refresh()
## Degrees per second of Earth spin when the day cycle is off. (Tied to the day cycle when it is on.)
@export var earth_spin_deg_per_sec := 0.5
## Blue-white fill light from the Earth, scaled by the Earth's phase.
@export_range(0.0, 1.0, 0.001) var earthshine_energy := 0.05:
	set(v):
		earthshine_energy = v
		_refresh()

@export_group("Stars")
@export_range(0.0, 8.0, 0.01) var star_brightness := 1.5:
	set(v):
		star_brightness = v
		_refresh()
@export_range(0.0, 8.0, 0.01) var milky_way_intensity := 1.0:
	set(v):
		milky_way_intensity = v
		_refresh()
## Stars vanish in lunar daylight (the eye/camera is adapted to the bright ground). 0 = invisible by
## day, 1 = always fully visible. At night they always show fully.
@export_range(0.0, 1.0, 0.01) var star_daylight_visibility := 0.12:
	set(v):
		star_daylight_visibility = v
		_refresh()

@export_group("Lighting")
## Fill light bounced from sunlit regolith into the shadows. Fades with the sun's elevation.
@export_range(0.0, 1.0, 0.001) var ambient_energy := 0.3:
	set(v):
		ambient_energy = v
		_refresh()
@export_range(0.1, 4.0, 0.01) var exposure := 1.0:
	set(v):
		exposure = v
		_refresh()
@export var tonemapper: Environment.ToneMapper = Environment.TONE_MAPPER_FILMIC:
	set(v):
		tonemapper = v
		_refresh()
## Lens glow around the sun and the brightest Earth clouds.
@export var bloom := true:
	set(v):
		bloom = v
		_refresh()

@export_group("Observer")
## The player. Its up axis sets the local horizon (sun elevation, ambient, star visibility).
## Left empty, it is found automatically at runtime.
@export var observer: Node3D
## Used when there is no observer and no parent MoonPlanet to read a spawn point from.
@export var fallback_up := Vector3(0.0, 0.0, 1.0)


func _ready() -> void:
	_sun = get_node_or_null("Sun") as DirectionalLight3D
	_earthlight = get_node_or_null("Earthshine") as DirectionalLight3D
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we:
		_env = we.environment
		if _env and _env.sky:
			_sky_mat = _env.sky.sky_material as ShaderMaterial
	_sun_lon = subsolar_longitude_deg
	_apply()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var spin := earth_spin_deg_per_sec
	if day_cycle_enabled:
		# The sub-solar point drifts west; Earth spins ~29.5 times per lunar day.
		var day := maxf(lunar_day_seconds, 1.0)
		_sun_lon = wrapf(_sun_lon - 360.0 * delta / day, -180.0, 180.0)
		spin = 360.0 * SYNODIC_DAYS / day
	_earth_rot = fposmod(_earth_rot + deg_to_rad(spin) * delta, TAU)
	if observer == null or not is_instance_valid(observer):
		_search_cd -= delta
		if _search_cd <= 0.0:
			_search_cd = 0.5
			observer = _find_player(get_tree().root)
	_apply()


# ---------------------------------------------------------------- public helpers
func get_sun_direction() -> Vector3:
	return _dir(_sun_lon, subsolar_latitude_deg)


func get_earth_direction() -> Vector3:
	return _dir(earth_longitude_deg, earth_latitude_deg)


## Sun elevation above the observer's local horizon, in degrees.
func get_sun_elevation_deg() -> float:
	return rad_to_deg(asin(clampf(_observer_up().dot(get_sun_direction()), -1.0, 1.0)))


## Place the sun by direction (world/planet space, pointing toward the sun).
func set_sun_direction(dir: Vector3) -> void:
	var n := dir.normalized()
	subsolar_latitude_deg = rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	subsolar_longitude_deg = rad_to_deg(atan2(n.x, n.z))


# ---------------------------------------------------------------- internals
func _refresh() -> void:
	if is_node_ready():
		_apply()


static func _dir(lon_deg: float, lat_deg: float) -> Vector3:
	var lon := deg_to_rad(lon_deg)
	var lat := deg_to_rad(lat_deg)
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


static func _orient(light: Node3D, toward: Vector3) -> void:
	var hint := Vector3.UP if absf(toward.y) < 0.99 else Vector3.RIGHT
	light.global_basis = Basis.looking_at(-toward, hint)


func _observer_up() -> Vector3:
	if observer != null and is_instance_valid(observer):
		return observer.global_basis.y.normalized()
	# Editor / pre-spawn: use the planet's spawn point, which is where the player starts.
	var n := get_parent()
	while n != null:
		if n is MoonPlanet:
			var moon := n as MoonPlanet
			return _dir(moon.spawn_lon_deg, moon.spawn_lat_deg)
		n = n.get_parent()
	return fallback_up.normalized()


func _find_player(n: Node) -> Node3D:
	if n is MoonPlayer:
		return n as Node3D
	for c in n.get_children():
		var r := _find_player(c)
		if r != null:
			return r
	return null


# Fraction of the sun's disc covered by the Earth's disc (circle-circle overlap).
func _eclipse_cover(sun_dir: Vector3, earth_dir: Vector3) -> float:
	if not earth_enabled:
		return 0.0
	var d := acos(clampf(earth_dir.dot(sun_dir), -1.0, 1.0))
	var rs := deg_to_rad(sun_angular_diameter_deg * 0.5)
	var re := deg_to_rad(earth_angular_diameter_deg * 0.5)
	if d >= rs + re:
		return 0.0
	if d <= re - rs:
		return 1.0
	if d <= rs - re:
		return (re * re) / (rs * rs)
	var a1 := acos(clampf((d * d + rs * rs - re * re) / (2.0 * d * rs), -1.0, 1.0))
	var a2 := acos(clampf((d * d + re * re - rs * rs) / (2.0 * d * re), -1.0, 1.0))
	var tri := sqrt(maxf((-d + rs + re) * (d + rs - re) * (d - rs + re) * (d + rs + re), 0.0))
	var area := rs * rs * a1 + re * re * a2 - 0.5 * tri
	return clampf(area / (PI * rs * rs), 0.0, 1.0)


func _apply() -> void:
	if _sun == null or _env == null:
		return
	var sun_dir := _dir(_sun_lon, subsolar_latitude_deg)
	var earth_dir := _dir(earth_longitude_deg, earth_latitude_deg)
	var up := _observer_up()
	var sin_elev := up.dot(sun_dir)
	var elev_deg := rad_to_deg(asin(clampf(sin_elev, -1.0, 1.0)))
	var cover := _eclipse_cover(sun_dir, earth_dir)
	var phase := 0.5 * (1.0 - earth_dir.dot(sun_dir))     # lit fraction of the Earth as seen from the Moon

	# Sun: hard-edged parallel light, dimmed and reddened during an eclipse.
	_orient(_sun, sun_dir)
	_sun.light_energy = sun_energy * (1.0 - 0.985 * cover)
	_sun.light_color = sun_color.lerp(Color(1.0, 0.36, 0.12), cover)
	_sun.light_angular_distance = sun_angular_diameter_deg
	_sun.shadow_enabled = sun_shadows

	# Earthshine: faint blue fill from the Earth's direction, strongest at full Earth.
	if _earthlight:
		_orient(_earthlight, earth_dir)
		_earthlight.visible = earth_enabled and earthshine_energy > 0.0
		_earthlight.light_energy = earthshine_energy * phase

	# Regolith bounce: shadows are dark but never pure black while the ground is sunlit.
	_env.ambient_light_color = Color(1.0, 0.97, 0.93)
	_env.ambient_light_energy = ambient_energy * lerpf(0.03, 1.0, sqrt(clampf(sin_elev, 0.0, 1.0)))
	_env.tonemap_mode = tonemapper
	_env.tonemap_exposure = exposure
	_env.glow_enabled = bloom

	if _sky_mat:
		var night := 1.0 - smoothstep(-3.0, 8.0, elev_deg)
		_sky_mat.set_shader_parameter("sun_dir", sun_dir)
		_sky_mat.set_shader_parameter("sun_color", sun_color)
		_sky_mat.set_shader_parameter("sun_angular_radius_deg", sun_angular_diameter_deg * 0.5)
		_sky_mat.set_shader_parameter("earth_enabled", 1.0 if earth_enabled else 0.0)
		_sky_mat.set_shader_parameter("earth_dir", earth_dir)
		_sky_mat.set_shader_parameter("earth_angular_radius_deg", earth_angular_diameter_deg * 0.5)
		_sky_mat.set_shader_parameter("earth_rotation", _earth_rot)
		_sky_mat.set_shader_parameter("earth_brightness", earth_brightness)
		_sky_mat.set_shader_parameter("star_brightness", star_brightness)
		_sky_mat.set_shader_parameter("milky_way_intensity", milky_way_intensity)
		_sky_mat.set_shader_parameter("star_visibility", lerpf(star_daylight_visibility, 1.0, night))
