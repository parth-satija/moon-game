@tool
extends Node3D
class_name MoonPlanet

@export var player: Node3D
@export var heightmap_path := "res://moon.r32"
@export var meta_path := "res://moon.json"
@export var material: Material
@export var color_path := "res://moon.rgb"
@export var topo_albedo := true            # derive surface darkness from topography (NASA LOLA trends), not the color map
@export var use_vertex_color := false     # legacy: load the moon.rgb color map instead
@export var color_lod_bias := 0.5           # >0 blurs far vertex colors more (stops aliasing blobs)
@export var use_detail_shader := true      # procedural craters/rocks/regolith on top of the color map

@export_group("Scale")
@export var real_radius_m := 1737400.0
@export var world_scale := 1.0              # 1.0 = real size; 0.1 = a 10x smaller moon
@export var height_exaggeration := 1.0

@export_group("Spawn")
@export var spawn_lat_deg := 0.0
@export var spawn_lon_deg := 0.0
@export var spawn_height_m := 3.0
@export var place_default_rover := true    # the demo rover at lon 0.0005; the GameState autoload turns it off and lays out the world itself

@export_group("Mesh LOD")
@export var first_ring_m := 3.0           # distance of the first ring from the player
@export var ring_growth := 1.05             # ~ 2*PI/segments keeps triangles roughly square
@export var segments := 128
@export var max_arc := PI                   # PI = whole globe
@export var rebuild_distance_m := 4.0     # re-centre the mesh this often (keep it below detail_near_m / 2)
@export var predict_rebuild_center := true   # build the next mesh around where the player WILL be when the (slow) build lands
@export var max_lead_m := 40.0                # never aim further ahead than this

@export_group("Physics")
@export var gravity := 1.62
@export var collision_radius_m := 1500.0
@export var align_player := true
@export var rebase_distance_m := 1000.0
@export var rebase_group := "rebase"

@export_group("Terrain Detail")
@export var terrain_detail := true                  # vertex-shader relief, bumps and craters (collision matches)
@export var detail_amount := 1.0                    # master scale for all displacement
@export var detail_slope := 0.06                    # rolling-relief steepness (rise/run): ~0.035 maria ... ~0.13 highlands
@export var detail_bumps := 1.0                     # random small mounds and hollows
@export var detail_bump_density := 0.4
@export var detail_craters := 1.0                   # crater depth scale
@export var detail_crater_density := 0.45
@export var detail_collision_radius_m := 1500.0     # displacement is mirrored into collision out to here (keep >= collision_radius_m so there is no step)
@export var detail_near_m := 8.0                    # within this distance of the player the detail fade is constant (hides mesh rebuilds)
@export_subgroup("Large-scale relief (fixed in the world)")
@export var far_amount := 1.0                       # big craters + broad rolling terrain; 0 = off. Fixed in world space, not tied to the player
@export var far_crater_density := 0.35
@export var far_crater_depth := 1.0

@export_group("Safety")
@export var rescue_underground := true       # lift the player back out if it ever ends up below the terrain
@export var rescue_margin_m := 0.3          # how far the feet may be under the collision surface before that happens
@export var rescue_clearance_m := 0.4       # how far above the surface the player is put back

var gravity_vector := Vector3.DOWN * 1.62
var _deep_check_at := 0                       # next time (msec) the analytic deep-fall check may run
var planet_radius_m := 1737400.0

var _data: PackedFloat32Array
var _w := 0
var _h := 0
var _mean := 1.0
var _col: PackedByteArray
var _cw := 0
var _ch := 0
var _has_color := false
var _off := [0.0, 0.0, 0.0]     # true (planet-centered) position of the engine origin, doubles
var _o := [0.0, 0.0, 0.0]       # true position of the current mesh origin
var _mi: MeshInstance3D
var _body: StaticBody3D
var _shape: ConcavePolygonShape3D
var _thread := Thread.new()
var _detail_mat: ShaderMaterial
var _col_mips: Array = []                    # PackedByteArray per mip level 1..n (level 0 is _col)
var _mip_w := PackedInt32Array()
var _mip_h := PackedInt32Array()
var _h_mips: Array = []                      # PackedFloat32Array per heightmap mip level 1..n
var _hm_w := PackedInt32Array()
var _hm_h := PackedInt32Array()
var _height_tex: ImageTexture
var _rmin := 1.0
var _rmax := 1.0
var _spread := 0.049                         # ring spacing as a fraction of distance from the mesh centre
var _detail_on := false
const REAL_RADIUS_KM := 1737.4               # LOLA reference radius (the elevation datum)
const LOLA_RELIEF_KM := 19.9                 # real global relief: +10.785 km to -9.129 km
var _texel_m := 1.0                          # metres per color-map texel (latitude direction)

# Persistent impact craters, stored flat: CRATER_STRIDE doubles per crater =
# [dir.x, dir.y, dir.z, radius_m, depth_m, rim_m, max_chord_sq]. Read by the mesh thread via a snapshot.
const CRATER_STRIDE := 7
static var instance: MoonPlanet                # the active moon, so craters can be made from anywhere
var _impact_craters := PackedFloat64Array()
var _crater_mutex := Mutex.new()
var _crater_dirty := false
var _job_start_us := 0                          # when the running mesh build started (microseconds)
var _build_secs := 0.0                          # smoothed wall-clock duration of a mesh build (seconds)


func _ready() -> void:
	instance = self
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
	_w = int(meta.width); _h = int(meta.height); _mean = float(meta.mean_radius)
	_rmin = float(meta.get("radius_min", _mean))
	_rmax = float(meta.get("radius_max", _mean))
	_data = FileAccess.get_file_as_bytes(heightmap_path).to_float32_array()
	assert(_data.size() == _w * _h, "heightmap size mismatch")
	_has_color = use_vertex_color and meta.has("color_width") and FileAccess.file_exists(color_path)
	if _has_color:
		_cw = int(meta.color_width); _ch = int(meta.color_height)
		_col = FileAccess.get_file_as_bytes(color_path)
		if _col.size() != _cw * _ch * 3:
			push_warning("color map size mismatch, ignoring colors")
			_has_color = false
	planet_radius_m = real_radius_m * world_scale
	_texel_m = PI * planet_radius_m / float(_ch if _has_color else _h)
	_spread = maxf(TAU / segments, ring_growth - 1.0)
	if _has_color:
		_build_color_mips()
	_build_height_mips()

	_mi = MeshInstance3D.new(); _mi.top_level = true
	_mi.material_override = material if material else _default_material()
	_detail_mat = _mi.material_override as ShaderMaterial
	_setup_terrain_detail()
	_setup_topo_albedo()
	add_child(_mi)
	_body = StaticBody3D.new(); _body.top_level = true
	var col := CollisionShape3D.new()
	_shape = ConcavePolygonShape3D.new(); _shape.backface_collision = true
	col.shape = _shape
	_body.add_child(col); add_child(_body)

	# Spawn: engine origin is placed at the player's true position.
	var lat := deg_to_rad(spawn_lat_deg); var lon := deg_to_rad(spawn_lon_deg)
	var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	var rb := _sample_m(dir)
	var r := rb + spawn_height_m
	if _detail_on:
		r += _detail_height_at(dir.x * rb, dir.y * rb, dir.z * rb)      # stand on the displaced ground
	_off = [dir.x * r, dir.y * r, dir.z * r]
	_update_detail_offsets()
	if player:
		player.global_position = Vector3.ZERO
	_first_build()      # first mesh, synchronous

	# A path string (not preload) is loaded at runtime, which avoids a cyclic reference: rover1.gd
	# refers back to MoonPlanet, so preloading the rover scene here would make moon.gd depend on itself.
	if place_default_rover:
		place_scene_at("res://scenes/rover1.tscn", 0.0005, 0.0)


func _physics_process(_dt: float) -> void:
	if player == null or _data.is_empty():
		return

	# --- floating origin ---
	var pp := player.global_position
	if pp.length() > rebase_distance_m:
		for k in 3:
			_off[k] += pp[k]
		player.global_position = Vector3.ZERO
		for nd in get_tree().get_nodes_in_group(rebase_group):
			if nd is Node3D and nd != player:
				nd.global_position -= pp
		pp = Vector3.ZERO
		_update_detail_offsets()

	var tx: float = _off[0] + pp.x
	var ty: float = _off[1] + pp.y
	var tz: float = _off[2] + pp.z

	# --- up / gravity ---
	var up := Vector3(tx, ty, tz).normalized()
	gravity_vector = -up * gravity
	if player is CharacterBody3D:
		player.up_direction = up
	if align_player:
		var q := Quaternion(player.global_basis.y.normalized(), up)
		player.global_basis = (Basis(q) * player.global_basis).orthonormalized()

	# --- terrain streaming ---
	if _thread.is_started() and not _thread.is_alive():
		_apply(_thread.wait_to_finish())
		_note_build_time()
	if not _thread.is_started():
		var dx: float = tx - _o[0]; var dy: float = ty - _o[1]; var dz: float = tz - _o[2]
		if _crater_dirty or sqrt(dx * dx + dy * dy + dz * dz) > rebuild_distance_m:
			_crater_dirty = false
			_start_build(tx, ty, tz)

	var pos := Vector3(_o[0] - _off[0], _o[1] - _off[1], _o[2] - _off[2])
	_mi.position = pos
	_body.position = pos
	_update_player_local(tx, ty, tz)
	_rescue_player_if_underground()


# ============================================================================
# Anti-fall safety net.
#
# The terrain collision is a thin, one-layer triangle mesh that gets swapped for a new one every few
# metres. On steep slopes the new mesh can differ from the old one by tens of centimetres under the
# player (a horizontal shift of x moves the surface by x * tan(slope)), which can leave the capsule
# below the surface. Nothing then pushes it back up, so it falls towards the planet's centre forever.
#
# The terrain is a heightfield along the radial direction, so a ray cast straight down the player's
# up axis meets the terrain at most once, and only when the feet are below it. If that happens the
# player is put back on top of it.
func _rescue_player_if_underground() -> void:
	if not rescue_underground or Engine.is_editor_hint() or _shape == null:
		return
	if not (player is CharacterBody3D):
		return
	var body := player as CharacterBody3D
	var up := body.up_direction
	var feet := body.global_position
	var space := get_world_3d().direct_space_state
	var exclude: Array[RID] = [body.get_rid()]
	var from := feet + up * 3000.0
	var to := feet + up * rescue_margin_m
	for _i in 4:
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.exclude = exclude
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			_rescue_deep_check(body, up, feet)          # no terrain above the feet: make sure they are not far below it
			return
		var collider := hit["collider"] as Node
		if collider != null and collider.get_parent() == self:
			var surface: Vector3 = hit["position"]
			body.global_position = surface + up * rescue_clearance_m
			body.velocity -= up * body.velocity.dot(up)     # keep the sideways motion, drop the fall
			print("MoonPlanet: lifted the player out of the terrain")
			return
		exclude.append(hit["rid"])                          # a rover / wreck / debris: look through it


# Backup for a fall that is deeper than the ray reaches, or where the collision mesh is missing under
# the player altogether: compare against the analytic ground height (heightmap + craters + detail).
func _rescue_deep_check(body: CharacterBody3D, up: Vector3, feet: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now < _deep_check_at:
		return
	_deep_check_at = now + 500
	var tx: float = _off[0] + feet.x
	var ty: float = _off[1] + feet.y
	var tz: float = _off[2] + feet.z
	var r := sqrt(tx * tx + ty * ty + tz * tz)
	if r < 1.0:
		return
	var g := _ground_point([tx / r, ty / r, tz / r])
	var gr := sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2])
	if r < gr - 50.0:
		body.global_position = Vector3(g[0] - _off[0], g[1] - _off[1], g[2] - _off[2]) + up * 3.0
		body.velocity -= up * body.velocity.dot(up)
		print("MoonPlanet: the player had fallen far under the ground, put back on the surface")


# Keeps a character above the terrain WITHOUT asking the physics engine. The ground is a mathematical
# function (heightmap + craters + detail), so its height under any point can be computed directly.
# If the character's feet are more than margin_m below that height they are moved up onto it, with
# clearance_m to spare, and any downward speed is cancelled. Returns how far it lifted (0 = not needed).
#
# This is the floor that cannot be lost. The collision mesh is built on a lagging thread and swapped
# under the player, so it can be stale, missing or swapped to a position that leaves the capsule
# inside it. This does not depend on any of that. margin_m has to cover how far the triangle mesh may
# legitimately sit below the exact surface (a chord across a bump), or the player would be lifted off
# the mesh it is standing on.
func ensure_above_ground(body: CharacterBody3D, margin_m: float, clearance_m: float) -> float:
	if _data.is_empty():
		return 0.0
	var feet := body.global_position
	var tx: float = _off[0] + feet.x
	var ty: float = _off[1] + feet.y
	var tz: float = _off[2] + feet.z
	var r := sqrt(tx * tx + ty * ty + tz * tz)
	if r < 1.0:
		return 0.0
	var inv := 1.0 / r
	var g := _ground_point([tx * inv, ty * inv, tz * inv], false, true)
	var depth := sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]) - r         # > 0: the ground is above the feet
	if depth <= margin_m:
		return 0.0
	var up := Vector3(tx * inv, ty * inv, tz * inv)
	body.global_position = feet + up * (depth + clearance_m)
	body.velocity -= up * minf(body.velocity.dot(up), 0.0)
	return depth


# Puts a body on the exact ground under it, whether that means lifting OR lowering it (ensure_above_ground()
# only lifts). Use it right after moving a body a long way, e.g. a teleport: the height is measured as if the
# body were already there, so it does not arrive too high or too low. Returns how far it moved (metres, + = up).
func snap_to_ground(body: Node3D, clearance_m := 0.05) -> float:
	if _data.is_empty():
		return 0.0
	var feet := body.global_position
	var tx: float = _off[0] + feet.x
	var ty: float = _off[1] + feet.y
	var tz: float = _off[2] + feet.z
	var r := sqrt(tx * tx + ty * ty + tz * tz)
	if r < 1.0:
		return 0.0
	var inv := 1.0 / r
	var g := _ground_point([tx * inv, ty * inv, tz * inv], true)
	var delta := sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]) + clearance_m - r
	body.global_position = feet + Vector3(tx * inv, ty * inv, tz * inv) * delta
	return delta


# How far a body's feet are above the exact ground (metres; negative = below it).
func height_above_ground(body: Node3D) -> float:
	if _data.is_empty():
		return 0.0
	var feet := body.global_position
	var tx: float = _off[0] + feet.x
	var ty: float = _off[1] + feet.y
	var tz: float = _off[2] + feet.z
	var r := sqrt(tx * tx + ty * ty + tz * tz)
	if r < 1.0:
		return 0.0
	var inv := 1.0 / r
	var g := _ground_point([tx * inv, ty * inv, tz * inv], true)
	return r - sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2])


func _first_build() -> void:
	var t0 := Time.get_ticks_usec()
	_apply(_build_job(_off[0], _off[1], _off[2]))
	_build_secs = float(Time.get_ticks_usec() - t0) / 1.0e6      # seed the latency estimate used for look-ahead


# Starts a background mesh build. The build takes seconds (the terrain displacement is evaluated in
# GDScript for every collision vertex) and the player keeps walking in the meantime. Centring the new
# mesh on where the player WAS when the build started means that, by the time it is swapped in, the
# player is 'speed * build time' away from its centre: out in the coarse outer rings, and further than
# detail_near_m from the point the collision's detail fade is measured from (the shader measures it
# from the live player). The collision then has less relief than the visible ground, so the player
# sinks into bumps, and the ground under the feet pops at every swap. Aim at the landing spot instead.
func _start_build(tx: float, ty: float, tz: float) -> void:
	var lead := Vector3.ZERO
	if predict_rebuild_center:
		lead = _lead_vector()
	_job_start_us = Time.get_ticks_usec()
	_thread.start(_build_job.bind(tx + lead.x, ty + lead.y, tz + lead.z))


func _note_build_time() -> void:
	var secs := float(Time.get_ticks_usec() - _job_start_us) / 1.0e6
	_build_secs = secs if _build_secs <= 0.0 else lerpf(_build_secs, secs, 0.5)


# How far the player is expected to travel along the ground while a build runs (engine-space metres).
func _lead_vector() -> Vector3:
	if not (player is CharacterBody3D):
		return Vector3.ZERO
	var body := player as CharacterBody3D
	var up := body.up_direction
	var v := body.get_real_velocity()
	v -= up * v.dot(up)                                  # only the part along the ground
	var lead := v * minf(_build_secs, 10.0)
	if lead.length() > max_lead_m:
		lead = lead.normalized() * max_lead_m
	return lead


func _exit_tree() -> void:
	if instance == self:
		instance = null
	if _thread.is_started():
		_thread.wait_to_finish()


# Surface radius in meters along a unit direction (bilinear). Thread-safe.
func _sample_m(dir: Vector3) -> float:
	var lon := atan2(dir.x, dir.z)
	var lat := asin(clampf(dir.y, -1.0, 1.0))
	var u := (lon / TAU + 0.5) * _w - 0.5
	var v := (0.5 - lat / PI) * _h - 0.5
	var x0 := int(floor(u)); var y0 := int(floor(v))
	var fx := u - x0; var fy := v - y0
	
	
	var rm := _bicubic(x0, y0, fx, fy)
	
	
	return planet_radius_m * (1.0 + (rm / _mean - 1.0) * height_exaggeration)


# Bilinear RGB sample from the raw color map. Thread-safe.
func _sample_color(dir: Vector3) -> Color:
	var lon := atan2(dir.x, dir.z)
	var lat := asin(clampf(dir.y, -1.0, 1.0))
	var u := (lon / TAU + 0.5) * _cw - 0.5
	var v := (0.5 - lat / PI) * _ch - 0.5
	var x0 := int(floor(u)); var y0 := int(floor(v))
	var fx := u - x0; var fy := v - y0
	var xa := posmod(x0, _cw); var xb := posmod(x0 + 1, _cw)
	var ya := clampi(y0, 0, _ch - 1); var yb := clampi(y0 + 1, 0, _ch - 1)
	var i00 := (ya * _cw + xa) * 3; var i10 := (ya * _cw + xb) * 3
	var i01 := (yb * _cw + xa) * 3; var i11 := (yb * _cw + xb) * 3
	var c := [0.0, 0.0, 0.0]
	for k in 3:
		var top := lerpf(_col[i00 + k], _col[i10 + k], fx)
		var bot := lerpf(_col[i01 + k], _col[i11 + k], fx)
		c[k] = lerpf(top, bot, fy) / 255.0
	return Color(c[0], c[1], c[2])


# Area-averaged copies of the color map. The far mesh rings are ~100 km apart, far coarser than
# the 1.3 km/px map, so point-sampling it there aliases into bright polygon blobs.
func _build_color_mips() -> void:
	var img := Image.create_from_data(_cw, _ch, false, Image.FORMAT_RGB8, _col)
	img.generate_mipmaps()
	var all := img.get_data()
	var n := img.get_mipmap_count()
	_col_mips.clear(); _mip_w.clear(); _mip_h.clear()
	for l in range(1, n + 1):
		var w := maxi(_cw >> l, 1)
		var h := maxi(_ch >> l, 1)
		var start := img.get_mipmap_offset(l)
		_col_mips.append(all.slice(start, start + w * h * 3))
		_mip_w.append(w)
		_mip_h.append(h)


# Bilinear RGB sample from one mip level (level >= 1). Thread-safe.
func _sample_mip(dir: Vector3, data: PackedByteArray, w: int, h: int) -> Color:
	var lon := atan2(dir.x, dir.z)
	var lat := asin(clampf(dir.y, -1.0, 1.0))
	var u := (lon / TAU + 0.5) * w - 0.5
	var v := (0.5 - lat / PI) * h - 0.5
	var x0 := int(floor(u)); var y0 := int(floor(v))
	var fx := u - x0; var fy := v - y0
	var xa := posmod(x0, w); var xb := posmod(x0 + 1, w)
	var ya := clampi(y0, 0, h - 1); var yb := clampi(y0 + 1, 0, h - 1)
	var i00 := (ya * w + xa) * 3; var i10 := (ya * w + xb) * 3
	var i01 := (yb * w + xa) * 3; var i11 := (yb * w + xb) * 3
	var c := [0.0, 0.0, 0.0]
	for k in 3:
		var top := lerpf(data[i00 + k], data[i10 + k], fx)
		var bot := lerpf(data[i01 + k], data[i11 + k], fx)
		c[k] = lerpf(top, bot, fy) / 255.0
	return Color(c[0], c[1], c[2])


func _sample_level(dir: Vector3, level: int) -> Color:
	if level == 0:
		return _sample_color(dir)
	return _sample_mip(dir, _col_mips[level - 1], _mip_w[level - 1], _mip_h[level - 1])


# Color at a level of detail (0 = full res, each +1 halves the resolution). Trilinear. Thread-safe.
func _sample_color_lod(dir: Vector3, lod: float) -> Color:
	var maxl := _col_mips.size()
	var lc := clampf(lod, 0.0, float(maxl))
	var l0 := int(floor(lc))
	var l1 := mini(l0 + 1, maxl)
	var c0 := _sample_level(dir, l0)
	if l1 == l0:
		return c0
	return c0.lerp(_sample_level(dir, l1), lc - float(l0))


# Area-averaged copies of the heightmap. Far mesh rings are many texels apart, so point-sampling
# the heightmap there aliases small craters into random lumpy (grainy) shading and silhouettes.
func _build_height_mips() -> void:
	var img := Image.create_from_data(_w, _h, false, Image.FORMAT_RF, _data.to_byte_array())
	img.generate_mipmaps()
	var all := img.get_data()
	var n := img.get_mipmap_count()
	_h_mips.clear(); _hm_w.clear(); _hm_h.clear()
	for l in range(1, n + 1):
		var w := maxi(_w >> l, 1)
		var h := maxi(_h >> l, 1)
		var start := img.get_mipmap_offset(l)
		_h_mips.append(all.slice(start, start + w * h * 4).to_float32_array())
		_hm_w.append(w)
		_hm_h.append(h)


# Raw heightmap value at one level (0 = full res, bicubic; >=1 = mip, bilinear). Thread-safe.
func _rm_level(dir: Vector3, level: int) -> float:
	var lon := atan2(dir.x, dir.z)
	var lat := asin(clampf(dir.y, -1.0, 1.0))
	if level == 0:
		var u0 := (lon / TAU + 0.5) * _w - 0.5
		var v0 := (0.5 - lat / PI) * _h - 0.5
		var xi := int(floor(u0)); var yi := int(floor(v0))
		return _bicubic(xi, yi, u0 - xi, v0 - yi)
	var w := _hm_w[level - 1]
	var h := _hm_h[level - 1]
	var d: PackedFloat32Array = _h_mips[level - 1]
	var u := (lon / TAU + 0.5) * w - 0.5
	var v := (0.5 - lat / PI) * h - 0.5
	var x0 := int(floor(u)); var y0 := int(floor(v))
	var fx := u - x0; var fy := v - y0
	var xa := posmod(x0, w); var xb := posmod(x0 + 1, w)
	var ya := clampi(y0, 0, h - 1); var yb := clampi(y0 + 1, 0, h - 1)
	var top := lerpf(d[ya * w + xa], d[ya * w + xb], fx)
	var bot := lerpf(d[yb * w + xa], d[yb * w + xb], fx)
	return lerpf(top, bot, fy)


# Surface radius in metres at a level of detail (matched to the local mesh spacing). Thread-safe.
func _sample_m_lod(dir: Vector3, lod: float, cr := PackedFloat64Array()) -> float:
	var maxl := _h_mips.size()
	if lod <= 0.0 or maxl == 0:
		return _sample_m(dir) + _crater_dh(dir, cr)
	var lc := clampf(lod, 0.0, float(maxl))
	var l0 := int(floor(lc))
	var l1 := mini(l0 + 1, maxl)
	var rm := _rm_level(dir, l0)
	if l1 != l0:
		rm = lerpf(rm, _rm_level(dir, l1), lc - float(l0))
	return planet_radius_m * (1.0 + (rm / _mean - 1.0) * height_exaggeration) + _crater_dh(dir, cr)


func _build_job(cx: float, cy: float, cz: float) -> Dictionary:
	var cl := sqrt(cx * cx + cy * cy + cz * cz)
	var n := Vector3(cx / cl, cy / cl, cz / cl)
	var ref := Vector3.UP if absf(n.y) < 0.99 else Vector3.RIGHT
	var t := ref.cross(n).normalized()
	var b := n.cross(t)
	_crater_mutex.lock()
	var cr := _impact_craters                           # snapshot (copy-on-write) so the main thread can add craters safely
	_crater_mutex.unlock()
	var rc := _sample_m_lod(n, 0.0, cr)          # mesh origin sits on the surface at n (including craters)

	var S := segments
	var dists: Array[float] = []
	var d := first_ring_m
	var d_max := max_arc * planet_radius_m
	while d < d_max:
		dists.append(d); d *= ring_growth
	dists.append(d_max)
	var N := dists.size()
	# Color LOD per ring: match the blur to the vertex spacing so the map is area-averaged, not point-sampled.
	var lods := PackedFloat32Array()
	var spread := maxf(TAU / S, ring_growth - 1.0)
	for dd in dists:
		lods.append(maxf(log(maxf(dd * spread, 1.0) / _texel_m) / log(2.0) + color_lod_bias, 0.0))

	var cp := PackedFloat64Array(); var sp := PackedFloat64Array()
	for j in S:
		cp.append(cos(TAU * j / S)); sp.append(sin(TAU * j / S))

	var verts := PackedVector3Array(); verts.resize(1 + N * S)
	verts[0] = Vector3.ZERO
	var cols := PackedColorArray()
	if _has_color:
		cols.resize(1 + N * S)
		cols[0] = _sample_color(n)
	var col_rings := 0
	for i in N:
		if dists[i] <= collision_radius_m:
			col_rings = i + 1
		var th: float = dists[i] / planet_radius_m
		var ct := cos(th); var st := sin(th)
		for j in S:
			var tang := t * cp[j] + b * sp[j]
			var dir := n * ct + tang * st
			if _has_color:
				cols[1 + i * S + j] = _sample_color_lod(dir, lods[i])
			var r := _sample_m_lod(dir, lods[i], cr)
			# position relative to mesh origin, kept small near the player
			verts[1 + i * S + j] = n * (r * ct - rc) + tang * (r * st)

	# Collision uses the same displacement the vertex shader applies, so what you see is what you stand on.
	var cv := verts
	if _detail_on:
		var o_x: float = n.x * rc
		var o_y: float = n.y * rc
		var o_z: float = n.z * rc
		var cache := {}
		cv = verts.duplicate()
		var det_rings := 0
		for i in N:
			if dists[i] <= detail_collision_radius_m:
				det_rings = i + 1
		cv[0] = _displaced(Vector3.ZERO, o_x, o_y, o_z, cache)
		for i in det_rings:
			for j in S:
				var di := 1 + i * S + j
				cv[di] = _displaced(verts[di], o_x, o_y, o_z, cache)

	var normals := PackedVector3Array(); normals.resize(verts.size())
	normals[0] = n
	for i in N:
		for j in S:
			var idx := 1 + i * S + j
			var inner: Vector3 = verts[0] if i == 0 else verts[1 + (i - 1) * S + j]
			var outer: Vector3 = verts[idx] if i == N - 1 else verts[1 + (i + 1) * S + j]
			var tg := verts[1 + i * S + (j + 1) % S] - verts[1 + i * S + (j - 1 + S) % S]
			var nn := (outer - inner).cross(tg)
			normals[idx] = nn.normalized() if nn.length_squared() > 0.0 else n

	var idxs := PackedInt32Array()
	var faces := PackedVector3Array()
	for j in S:
		var tri := [0, 1 + (j + 1) % S, 1 + j]
		idxs.append_array(tri)
		for k in tri: faces.append(cv[k])
	for i in N - 1:
		for j in S:
			var jn := (j + 1) % S
			var A := 1 + i * S + j;       var B := 1 + i * S + jn
			var Cc := 1 + (i + 1) * S + j; var D := 1 + (i + 1) * S + jn
			var quad := [A, B, Cc, B, D, Cc]
			idxs.append_array(quad)
			if i < col_rings:
				for k in quad: faces.append(cv[k])

	return {"verts": verts, "normals": normals, "idxs": idxs, "faces": faces, "cols": cols,
			"o": [n.x * rc, n.y * rc, n.z * rc]}


# ============================================================================
# Persistent impact craters.
#
# Craters are carved into the base surface radius (same path the heightmap takes), so they show up in
# the rendered mesh AND the collision shape, survive every mesh rebuild / floating-origin rebase, and
# the procedural shader detail sits on top of them.
#
#   MoonPlanet.impact_crater(lon_deg, lat_deg, radius_m)            # from anywhere (static)
#   moon.add_impact_crater(lon_deg, lat_deg, radius_m, 0.25)        # on an instance
#
# Longitude / latitude use the same convention as spawn_lon_deg / spawn_lat_deg.
# radius_m is the crater's bowl radius in world metres (i.e. after world_scale).
# depth_ratio = depth / radius (0.2 is a typical fresh simple crater); rim_ratio = rim height / depth.
# Rim and ejecta fall off out to ~3 radii, so the total footprint is about 3x radius.
static func impact_crater(lon_deg: float, lat_deg: float, radius_m: float, depth_ratio := 0.2, rim_ratio := 0.25) -> bool:
	if instance == null:
		push_warning("MoonPlanet.impact_crater: no active moon")
		return false
	instance.add_impact_crater(lon_deg, lat_deg, radius_m, depth_ratio, rim_ratio)
	return true


func add_impact_crater(lon_deg: float, lat_deg: float, radius_m: float, depth_ratio := 0.2, rim_ratio := 0.25) -> void:
	if radius_m <= 0.0:
		return
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	var depth := radius_m * maxf(depth_ratio, 0.0)
	var ang := minf(3.0 * radius_m / planet_radius_m, PI)
	var chord := 2.0 * sin(ang * 0.5)
	_crater_mutex.lock()
	var arr := _impact_craters.duplicate()
	arr.append_array(PackedFloat64Array([dir.x, dir.y, dir.z, radius_m, depth, depth * maxf(rim_ratio, 0.0), chord * chord]))
	_impact_craters = arr
	_crater_mutex.unlock()
	_crater_dirty = true                         # _physics_process rebuilds the mesh + collision on its next free slot


func clear_impact_craters() -> void:
	_crater_mutex.lock()
	_impact_craters = PackedFloat64Array()
	_crater_mutex.unlock()
	_crater_dirty = true


# Summed crater height change (metres) along a unit direction. Thread-safe (works on a snapshot).
# Uses chord length between unit vectors rather than acos(dot), which would lose all precision for
# metre-scale craters on a 1737 km sphere in float32.
func _crater_dh(dir: Vector3, cr: PackedFloat64Array) -> float:
	var h := 0.0
	var i := 0
	var n := cr.size()
	while i < n:
		var dx := dir.x - cr[i]
		var dy := dir.y - cr[i + 1]
		var dz := dir.z - cr[i + 2]
		var c2 := dx * dx + dy * dy + dz * dz
		if c2 <= cr[i + 6]:
			var s := planet_radius_m * 2.0 * asin(minf(sqrt(c2) * 0.5, 1.0))      # arc distance from the centre
			var rad: float = cr[i + 3]
			var x := s / rad
			if x < 1.0:
				h += cr[i + 4] * (x * x - 1.0)                                       # parabolic bowl
			var t := (x - 1.0) / 0.35
			h += cr[i + 5] * exp(-t * t)                                             # raised rim / ejecta blanket
		i += CRATER_STRIDE
	return h


# ============================================================================
# Placing scenes on the ground.
#
#   MoonPlanet.place_scene(scene, lon_deg, lat_deg)                           # from anywhere (static)
#   moon.place_scene_at(scene, lon_deg, lat_deg, yaw_deg, height_offset_m, normal_sample_m)
#
# `scene` is a PackedScene or a res:// path. The instance is aligned so its +Y is the ground normal
# (heightmap + craters + procedural shader detail, i.e. exactly what you see and stand on), then turned
# by yaw_deg around that normal (0 = its -Z points north). The normal is a central difference of the
# ground height 'normal_sample_m' either side, so use a value near the object's footprint radius; very
# small values just measure float noise. The instance joins the rebase group so it stays glued to the
# planet when the floating origin shifts. Returns the instance (null on failure).
# Note: collision only exists within collision_radius_m of the player, so physics bodies placed
# farther away than that have no ground to rest on until you get close.
static func place_scene(scene: Variant, lon_deg: float, lat_deg: float, yaw_deg := 0.0, height_offset_m := 0.0, normal_sample_m := 2.0) -> Node3D:
	if instance == null:
		push_warning("MoonPlanet.place_scene: no active moon")
		return null
	return instance.place_scene_at(scene, lon_deg, lat_deg, yaw_deg, height_offset_m, normal_sample_m)


func place_scene_at(scene: Variant, lon_deg: float, lat_deg: float, yaw_deg := 0.0, height_offset_m := 0.0, normal_sample_m := 2.0) -> Node3D:
	if _data.is_empty():
		push_warning("place_scene_at: moon not ready yet")
		return null
	var packed: PackedScene = null
	if scene is PackedScene:
		packed = scene
	elif scene is String or scene is StringName:
		packed = load(str(scene)) as PackedScene
	if packed == null:
		push_warning("place_scene_at: not a PackedScene / valid path")
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		push_warning("place_scene_at: scene root is not a Node3D")
		return null

	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var step := maxf(normal_sample_m, 0.1)
	var east := [cos(lon), 0.0, -sin(lon)]
	var north := [-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon)]
	var dir := [cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)]

	# Ground point under the spot, and four neighbours for the slope (all in doubles, planet-centred).
	var g0 := _ground_point(dir, true)
	var ge := _ground_point(_offset_dir(dir, east, step), true)
	var gw := _ground_point(_offset_dir(dir, east, -step), true)
	var gn := _ground_point(_offset_dir(dir, north, step), true)
	var gs := _ground_point(_offset_dir(dir, north, -step), true)
	var te := Vector3(ge[0] - gw[0], ge[1] - gw[1], ge[2] - gw[2])
	var tn := Vector3(gn[0] - gs[0], gn[1] - gs[1], gn[2] - gs[2])
	var normal := te.cross(tn).normalized()
	if normal.length_squared() < 0.5:                       # degenerate: fall back to the sphere normal
		normal = Vector3(dir[0], dir[1], dir[2])

	# Basis with +Y = ground normal, keeping a stable north-ish heading, then yaw around the normal.
	var e := Vector3(east[0], east[1], east[2])
	var x := (e - normal * e.dot(normal)).normalized()
	var z := x.cross(normal).normalized()                   # x cross y = z (right-handed)
	var basis := Basis(normal, deg_to_rad(-yaw_deg)) * Basis(x, normal, z)

	var p := Vector3(
		g0[0] + normal.x * height_offset_m - _off[0],
		g0[1] + normal.y * height_offset_m - _off[1],
		g0[2] + normal.z * height_offset_m - _off[2])

	add_child(inst)
	inst.global_transform = Transform3D(basis.orthonormalized(), p)
	inst.add_to_group(rebase_group)
	return inst


# Places a scene at a uniformly random spot inside a circle of radius_m (metres along the ground)
# around lon_deg / lat_deg, tilted to the ground like place_scene_at. random_yaw turns it to a random
# heading. Pass your own RandomNumberGenerator (with a seed) for repeatable layouts; otherwise the
# global random functions are used. Returns the instance (null on failure).
#   MoonPlanet.place_scene_random(preload("res://scenes/rover1.tscn"), 12.5, -3.0, 200.0)
static func place_scene_random(scene: Variant, lon_deg: float, lat_deg: float, radius_m: float, random_yaw := true, height_offset_m := 0.0, normal_sample_m := 2.0, rng: RandomNumberGenerator = null) -> Node3D:
	if instance == null:
		push_warning("MoonPlanet.place_scene_random: no active moon")
		return null
	return instance.place_scene_random_at(scene, lon_deg, lat_deg, radius_m, random_yaw, height_offset_m, normal_sample_m, rng)


func place_scene_random_at(scene: Variant, lon_deg: float, lat_deg: float, radius_m: float, random_yaw := true, height_offset_m := 0.0, normal_sample_m := 2.0, rng: RandomNumberGenerator = null) -> Node3D:
	var u1: float = rng.randf() if rng else randf()
	var u2: float = rng.randf() if rng else randf()
	var u3: float = rng.randf() if rng else randf()
	var dist := maxf(radius_m, 0.0) * sqrt(u1)               # sqrt gives uniform density over the disc
	var bearing := TAU * u2
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var north := Vector3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
	var tangent := east * cos(bearing) + north * sin(bearing)
	var th := dist / planet_radius_m                          # great-circle step from the centre
	var nd := dir * cos(th) + tangent * sin(th)
	var new_lat := rad_to_deg(asin(clampf(nd.y, -1.0, 1.0)))
	var new_lon := rad_to_deg(atan2(nd.x, nd.z))
	return place_scene_at(scene, new_lon, new_lat, 360.0 * u3 if random_yaw else 0.0, height_offset_m, normal_sample_m)


# Searches for a flat patch and places a scene on it. Candidate spots are picked at random in the ring
# between min_radius_m and search_radius_m around lon_deg / lat_deg (never closer than min_radius_m),
# and the first one whose footprint is flat enough wins.
#   flat_radius_m    radius of the footprint that has to be flat (about your scene's half-width)
#   max_slope_deg    overall tilt of the patch allowed (angle of the fitted plane from level)
#   max_roughness_m  how far any sampled point of the footprint may stray from that plane (craters, rocks)
#   attempts         candidate spots to try before giving up
# Heights include craters and the shader detail, so it also avoids your impact craters.
# Returns the placed instance, or null (with a warning) when nothing flat enough was found; loosen the
# tolerances, enlarge search_radius_m or raise attempts in that case.
#   MoonPlanet.place_scene_flat(preload("res://scenes/moon_base.tscn"), 12.5, -3.0, 15.0, 1000.0, 100.0)
static func place_scene_flat(scene: Variant, lon_deg: float, lat_deg: float, flat_radius_m: float, search_radius_m: float, min_radius_m := 0.0, max_slope_deg := 5.0, max_roughness_m := 0.25, attempts := 60, random_yaw := true, height_offset_m := 0.0, rng: RandomNumberGenerator = null) -> Node3D:
	if instance == null:
		push_warning("MoonPlanet.place_scene_flat: no active moon")
		return null
	return instance.place_scene_flat_at(scene, lon_deg, lat_deg, flat_radius_m, search_radius_m, min_radius_m, max_slope_deg, max_roughness_m, attempts, random_yaw, height_offset_m, rng)


func place_scene_flat_at(scene: Variant, lon_deg: float, lat_deg: float, flat_radius_m: float, search_radius_m: float, min_radius_m := 0.0, max_slope_deg := 5.0, max_roughness_m := 0.25, attempts := 60, random_yaw := true, height_offset_m := 0.0, rng: RandomNumberGenerator = null) -> Node3D:
	if _data.is_empty():
		push_warning("place_scene_flat_at: moon not ready yet")
		return null
	var fr := maxf(flat_radius_m, 0.5)
	var hi := maxf(search_radius_m, 0.0)
	var lo := clampf(min_radius_m, 0.0, hi)
	var slope_lim := maxf(max_slope_deg, 0.01)
	var rough_lim := maxf(max_roughness_m, 0.001)
	var best_score := INF
	var best: Array = []
	for i in maxi(attempts, 1):
		var u1: float = rng.randf() if rng else randf()
		var u2: float = rng.randf() if rng else randf()
		var dist := sqrt(lerpf(lo * lo, hi * hi, u1))           # uniform over the ring
		var ll := _lonlat_offset(lon_deg, lat_deg, dist, TAU * u2)
		var f := _flatness(ll[0], ll[1], fr)
		var score := maxf(f.x / slope_lim, f.y / rough_lim)       # <= 1 means both limits are met
		if score < best_score:
			best_score = score
			best = ll
		if score <= 1.0:
			break
	if best.is_empty() or best_score > 1.0:
		push_warning("place_scene_flat_at: no flat spot found (closest miss was %.1fx the limits)" % best_score)
		return null
	var yaw_u: float = rng.randf() if rng else randf()
	return place_scene_at(scene, best[0], best[1], 360.0 * yaw_u if random_yaw else 0.0, height_offset_m, fr)


# Slope (degrees of the fitted plane from level) and roughness (max distance of the footprint's sample
# points from that plane, metres) of the ground within 'radius' metres of a spot. x = slope, y = roughness.
func _flatness(lon_deg: float, lat_deg: float, radius: float) -> Vector2:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var east := [cos(lon), 0.0, -sin(lon)]
	var north := [-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon)]
	var dir := [cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon)]
	var g0 := _ground_point(dir, true)
	var pts: Array = []
	for k in 8:                                               # ring of 8: E, NE, N, NW, W, SW, S, SE
		var a := TAU * k / 8.0
		var t := [east[0] * cos(a) + north[0] * sin(a), east[1] * cos(a) + north[1] * sin(a), east[2] * cos(a) + north[2] * sin(a)]
		pts.append(_ground_point(_offset_dir(dir, t, radius), true))
	var te := Vector3(pts[0][0] - pts[4][0], pts[0][1] - pts[4][1], pts[0][2] - pts[4][2])
	var tn := Vector3(pts[2][0] - pts[6][0], pts[2][1] - pts[6][1], pts[2][2] - pts[6][2])
	var normal := te.cross(tn).normalized()
	var up := Vector3(dir[0], dir[1], dir[2])
	var slope := rad_to_deg(acos(clampf(normal.dot(up), -1.0, 1.0)))
	var rough := 0.0
	for p in pts:
		var v := Vector3(p[0] - g0[0], p[1] - g0[1], p[2] - g0[2])
		rough = maxf(rough, absf(v.dot(normal)))
	return Vector2(slope, rough)


# lon / lat (degrees, doubles) of the spot 'dist' metres from lon/lat along a compass bearing (radians, 0 = east).
func _lonlat_offset(lon_deg: float, lat_deg: float, dist: float, bearing: float) -> Array:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
	var east := Vector3(cos(lon), 0.0, -sin(lon))
	var north := Vector3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon))
	var tangent := east * cos(bearing) + north * sin(bearing)
	var th := dist / planet_radius_m
	var nd := dir * cos(th) + tangent * sin(th)
	return [rad_to_deg(atan2(nd.x, nd.z)), rad_to_deg(asin(clampf(nd.y, -1.0, 1.0)))]


# Unit direction displaced along a unit tangent by 'dist' metres (doubles).
func _offset_dir(dir: Array, tangent: Array, dist: float) -> Array:
	var k := dist / planet_radius_m
	var v := [dir[0] + tangent[0] * k, dir[1] + tangent[1] * k, dir[2] + tangent[2] * k]
	var l := sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
	return [v[0] / l, v[1] / l, v[2] / l]


# True (planet-centred, doubles) surface point along a unit direction: heightmap + craters + shader detail.
# as_if_near = true measures the ground as it looks to a player standing right there (all detail), instead of as
# it looks from where the player actually is. Anything that is PLACED must use it: the displacement fades out
# with distance from the player, so a base set down 15 km away on the faded ground sits tens of metres above or
# below the real ground once the player walks up to it (and a teleport there arrives just as far off).
func _ground_point(dir: Array, as_if_near := false, collision_basis := false) -> Array:
	var d := Vector3(dir[0], dir[1], dir[2])
	_crater_mutex.lock()
	var cr := _impact_craters
	_crater_mutex.unlock()
	var r := _sample_m(d) + _crater_dh(d, cr)
	var px: float = dir[0] * r
	var py: float = dir[1] * r
	var pz: float = dir[2] * r
	if _detail_on:
		# The shader fades its displacement with distance from the player, so mirror that here.
		# collision_basis = true instead mirrors the COLLISION mesh, which fades the detail with the vertex's
		# distance from the mesh's own centre (see _displaced). A floor check has to agree with the mesh the
		# player stands on, not with what the shader draws, or the two fight whenever the mesh was built
		# around a point some metres away from the player.
		var dist := 0.0
		if collision_basis:
			var cx: float = _o[0] - px
			var cy: float = _o[1] - py
			var cz: float = _o[2] - pz
			dist = sqrt(cx * cx + cy * cy + cz * cz)
		elif player and not as_if_near:
			var pp := player.global_position
			var ex: float = _off[0] + pp.x - px
			var ey: float = _off[1] + pp.y - py
			var ez: float = _off[2] + pp.z - pz
			dist = sqrt(ex * ex + ey * ey + ez * ez)
		r += _vtx_height(fposmod(px, 4096.0), fposmod(py, 4096.0), fposmod(pz, 4096.0),
			fposmod(px, 262144.0), fposmod(py, 262144.0), fposmod(pz, 262144.0), dist, {})
	return [dir[0] * r, dir[1] * r, dir[2] * r]


# ============================================================================
# Smooth heights: Catmull-Rom (C1) instead of bilinear, which leaves creases along texel edges.
func _cr(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)))


func _bicubic(x0: int, y0: int, fx: float, fy: float) -> float:
	var xs0 := posmod(x0 - 1, _w)
	var xs1 := posmod(x0, _w)
	var xs2 := posmod(x0 + 1, _w)
	var xs3 := posmod(x0 + 2, _w)
	var ra := clampi(y0 - 1, 0, _h - 1) * _w
	var rb := clampi(y0, 0, _h - 1) * _w
	var rc := clampi(y0 + 1, 0, _h - 1) * _w
	var rd := clampi(y0 + 2, 0, _h - 1) * _w
	return _cr(
		_cr(_data[ra + xs0], _data[ra + xs1], _data[ra + xs2], _data[ra + xs3], fx),
		_cr(_data[rb + xs0], _data[rb + xs1], _data[rb + xs2], _data[rb + xs3], fx),
		_cr(_data[rc + xs0], _data[rc + xs1], _data[rc + xs2], _data[rc + xs3], fx),
		_cr(_data[rd + xs0], _data[rd + xs1], _data[rd + xs2], _data[rd + xs3], fx),
		fy)


# ============================================================================
# Terrain detail. The vertex shader (moon_surface.gdshader) displaces the mesh with rolling relief,
# random small mounds/hollows and craters. This is the CPU mirror of that exact function, applied to
# the collision shape so what you see is what you stand on. It uses an integer hash, which is
# bit-identical on GPU and CPU. KEEP IN SYNC with vertex() in the shader (seeds, cells, masks).
const _M32 := 0xFFFFFFFF


static func _pcg(v: int) -> int:
	var state: int = (v * 747796405 + 2891336453) & _M32
	var word: int = (((state >> ((state >> 28) + 4)) ^ state) * 277803737) & _M32
	return ((word >> 22) ^ word) & _M32


static func _ihash(ix: int, iy: int, iz: int, mask: int, seed: int) -> int:
	var a := _pcg(((iz & mask) + seed) & _M32)
	var b := _pcg(((iy & mask) + a) & _M32)
	return _pcg(((ix & mask) + b) & _M32)


static func _h01(h: int) -> float:
	return float(h >> 8) / 16777216.0


# 3D value noise on a lattice that wraps every (mask + 1) cells. Returns 0..1.
func _vn(px: float, py: float, pz: float, mask: int, seed: int) -> float:
	var fx := floorf(px)
	var fy := floorf(py)
	var fz := floorf(pz)
	var ix := int(fx)
	var iy := int(fy)
	var iz := int(fz)
	var x := px - fx
	var y := py - fy
	var z := pz - fz
	var ux := x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
	var uy := y * y * y * (y * (y * 6.0 - 15.0) + 10.0)
	var uz := z * z * z * (z * (z * 6.0 - 15.0) + 10.0)
	var a := _h01(_ihash(ix, iy, iz, mask, seed))
	var b := _h01(_ihash(ix + 1, iy, iz, mask, seed))
	var c := _h01(_ihash(ix, iy + 1, iz, mask, seed))
	var d := _h01(_ihash(ix + 1, iy + 1, iz, mask, seed))
	var e := _h01(_ihash(ix, iy, iz + 1, mask, seed))
	var f := _h01(_ihash(ix + 1, iy, iz + 1, mask, seed))
	var g := _h01(_ihash(ix, iy + 1, iz + 1, mask, seed))
	var h := _h01(_ihash(ix + 1, iy + 1, iz + 1, mask, seed))
	return a + (b - a) * ux + (c - a) * uy + (e - a) * uz \
		+ (a - b - c + d) * ux * uy + (a - c - e + g) * uy * uz + (a - b - e + f) * uz * ux \
		+ (-a + b + c - d + e - f - g + h) * ux * uy * uz


# Rolling relief octave: wavelength ~ cell, steepness set by detail_slope.
func _und(px: float, py: float, pz: float, cell: float, mask: int, seed: int, s: float) -> float:
	var fade := smoothstep(2.0 * s, 6.0 * s, cell)
	if fade <= 0.0:
		return 0.0
	var amp := detail_slope * cell * 0.35 * fade
	return amp * (_vn(px / cell, py / cell, pz / cell, mask, seed) - 0.5)


# Same as _vn, but the 8 lattice values of a cell are hashed once and cached. The big octaves cover
# hundreds of vertices per cell, so this makes a mesh rebuild several times cheaper (a slow rebuild
# leaves the collision mesh stale, which is what makes the ground feel like it sinks).
func _vn_c(px: float, py: float, pz: float, mask: int, seed: int, cache: Dictionary) -> float:
	var fx := floorf(px)
	var fy := floorf(py)
	var fz := floorf(pz)
	var ix := int(fx)
	var iy := int(fy)
	var iz := int(fz)
	var x := px - fx
	var y := py - fy
	var z := pz - fz
	var ux := x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
	var uy := y * y * y * (y * (y * 6.0 - 15.0) + 10.0)
	var uz := z * z * z * (z * (z * 6.0 - 15.0) + 10.0)
	var dct := _cell_cache(cache, seed)
	var key := Vector3i(ix, iy, iz)
	var cv: Array
	if dct.has(key):
		cv = dct[key]
	else:
		cv = [_h01(_ihash(ix, iy, iz, mask, seed)), _h01(_ihash(ix + 1, iy, iz, mask, seed)),
			_h01(_ihash(ix, iy + 1, iz, mask, seed)), _h01(_ihash(ix + 1, iy + 1, iz, mask, seed)),
			_h01(_ihash(ix, iy, iz + 1, mask, seed)), _h01(_ihash(ix + 1, iy, iz + 1, mask, seed)),
			_h01(_ihash(ix, iy + 1, iz + 1, mask, seed)), _h01(_ihash(ix + 1, iy + 1, iz + 1, mask, seed))]
		dct[key] = cv
	var a: float = cv[0]
	var b: float = cv[1]
	var c: float = cv[2]
	var d: float = cv[3]
	var e: float = cv[4]
	var f: float = cv[5]
	var g: float = cv[6]
	var h: float = cv[7]
	return a + (b - a) * ux + (c - a) * uy + (e - a) * uz \
		+ (a - b - c + d) * ux * uy + (a - c - e + g) * uy * uz + (a - b - e + f) * uz * ux \
		+ (-a + b + c - d + e - f - g + h) * ux * uy * uz


func _und_c(px: float, py: float, pz: float, cell: float, mask: int, seed: int, s: float, cache: Dictionary) -> float:
	var fade := smoothstep(2.0 * s, 6.0 * s, cell)
	if fade <= 0.0:
		return 0.0
	var amp := detail_slope * cell * 0.35 * fade
	return amp * (_vn_c(px / cell, py / cell, pz / cell, mask, seed, cache) - 0.5)


# Cached per-cell feature records (a cell's feature never changes, so hash it once per rebuild).
func _cell_cache(cache: Dictionary, seed: int) -> Dictionary:
	if not cache.has(seed):
		cache[seed] = {}
	return cache[seed]


func _bump_cell(cx: int, cy: int, cz: int, mask: int, seed: int, cache: Dictionary) -> Array:
	var dct := _cell_cache(cache, seed)
	var key := Vector3i(cx, cy, cz)
	if dct.has(key):
		return dct[key]
	var rec: Array = []
	var h0 := _ihash(cx, cy, cz, mask, seed)
	if _h01(h0) <= detail_bump_density:
		var r1 := _pcg(h0)
		var r2 := _pcg(r1)
		var r3 := _pcg(r2)
		var r4 := _pcg(r3)
		var r5 := _pcg(r4)
		var r6 := _pcg(r5)
		# [centre xyz (cell units), radius (fraction of cell), signed height (fraction of radius)]
		rec = [cx + 0.2 + 0.6 * _h01(r1), cy + 0.2 + 0.6 * _h01(r2), cz + 0.2 + 0.6 * _h01(r3),
			0.08 + 0.2 * _h01(r4), (0.05 + 0.15 * _h01(r6)) * (1.0 if _h01(r5) < 0.7 else -0.6)]
	dct[key] = rec
	return rec


# Random small mounds (70%) and shallow hollows (30%).
func _bumps(px: float, py: float, pz: float, cell: float, mask: int, seed: int, s: float, cache: Dictionary) -> float:
	var fade := smoothstep(2.0 * s, 6.0 * s, cell * 0.4)
	if fade <= 0.0 or detail_bumps <= 0.0:
		return 0.0
	var qx := px / cell
	var qy := py / cell
	var qz := pz / cell
	var fx := floorf(qx)
	var fy := floorf(qy)
	var fz := floorf(qz)
	var i0x := int(fx)
	var i0y := int(fy)
	var i0z := int(fz)
	var sx := 1 if qx - fx >= 0.5 else -1
	var sy := 1 if qy - fy >= 0.5 else -1
	var sz := 1 if qz - fz >= 0.5 else -1
	var acc := 0.0
	for a in 2:
		for b in 2:
			for c in 2:
				var rec := _bump_cell(i0x + a * sx, i0y + b * sy, i0z + c * sz, mask, seed, cache)
				if rec.is_empty():
					continue
				var dx: float = (qx - rec[0]) * cell
				var dy: float = (qy - rec[1]) * cell
				var dz: float = (qz - rec[2]) * cell
				var rad: float = cell * rec[3]
				var x2 := (dx * dx + dy * dy + dz * dz) / (rad * rad)
				if x2 >= 1.0:
					continue
				var w := 1.0 - x2
				acc += fade * rad * float(rec[4]) * w * w
	return acc * detail_bumps


func _crater_cell(cx: int, cy: int, cz: int, mask: int, seed: int, cache: Dictionary) -> Array:
	var dct := _cell_cache(cache, seed)
	var key := Vector3i(cx, cy, cz)
	if dct.has(key):
		return dct[key]
	var rec: Array = []
	var h0 := _ihash(cx, cy, cz, mask, seed)
	if _h01(h0) <= detail_crater_density:
		var r1 := _pcg(h0)
		var r2 := _pcg(r1)
		var r3 := _pcg(r2)
		var r4 := _pcg(r3)
		var r5 := _pcg(r4)
		# [centre xyz (cell units), radius (fraction of cell), depth/radius]
		rec = [cx + 0.15 + 0.7 * _h01(r1), cy + 0.15 + 0.7 * _h01(r2), cz + 0.15 + 0.7 * _h01(r3),
			0.07 + 0.2 * _h01(r4), lerpf(0.05, 0.14, _h01(r5))]
	dct[key] = rec
	return rec


# Craters: parabolic bowl with a raised rim.
func _craters(px: float, py: float, pz: float, cell: float, mask: int, seed: int, s: float, cache: Dictionary) -> float:
	var fade := smoothstep(2.0 * s, 6.0 * s, cell * 0.2)
	if fade <= 0.0 or detail_craters <= 0.0:
		return 0.0
	var qx := px / cell
	var qy := py / cell
	var qz := pz / cell
	var fx := floorf(qx)
	var fy := floorf(qy)
	var fz := floorf(qz)
	var i0x := int(fx)
	var i0y := int(fy)
	var i0z := int(fz)
	var sx := 1 if qx - fx >= 0.5 else -1
	var sy := 1 if qy - fy >= 0.5 else -1
	var sz := 1 if qz - fz >= 0.5 else -1
	var acc := 0.0
	for a in 2:
		for b in 2:
			for c in 2:
				var rec := _crater_cell(i0x + a * sx, i0y + b * sy, i0z + c * sz, mask, seed, cache)
				if rec.is_empty():
					continue
				var dx: float = (qx - rec[0]) * cell
				var dy: float = (qy - rec[1]) * cell
				var dz: float = (qz - rec[2]) * cell
				var dlen := maxf(sqrt(dx * dx + dy * dy + dz * dz), 1e-4)
				var rad: float = cell * rec[3]
				var x := dlen / rad
				if x > 1.9:
					continue
				var dr: float = float(rec[4]) * detail_craters
				var inside := 1.0 if x < 1.0 else 0.0
				var t := (x - 1.0) / 0.3
				var rim := 0.35 * dr * exp(-t * t)
				acc += fade * rad * (inside * dr * (x * x - 1.0) + rim)
	return acc


# Large-scale relief, mirror of vcrater_real() in the shader: bowl, raised rim, power-law ejecta blanket
# and a central peak on ~1/3 of craters. Unlike the fine layers it is NOT faded in with distance from
# the player, so these shapes stay put in the world; only the resolution fade (s) removes them far away.
func _creal_cell(cx: int, cy: int, cz: int, mask: int, seed: int, density: float, cache: Dictionary) -> Array:
	var dct := _cell_cache(cache, seed)
	var key := Vector3i(cx, cy, cz)
	if dct.has(key):
		return dct[key]
	var rec: Array = []
	var h0 := _ihash(cx, cy, cz, mask, seed)
	if _h01(h0) <= density:
		var r1 := _pcg(h0)
		var r2 := _pcg(r1)
		var r3 := _pcg(r2)
		var r4 := _pcg(r3)
		var r5 := _pcg(r4)
		var r6 := _pcg(r5)
		# [centre xyz (cell units), radius (fraction of cell), depth/radius, has central peak]
		rec = [cx + 0.15 + 0.7 * _h01(r1), cy + 0.15 + 0.7 * _h01(r2), cz + 0.15 + 0.7 * _h01(r3),
			0.07 + 0.2 * _h01(r4), lerpf(0.05, 0.14, _h01(r5)), _h01(r6) < 0.35]
	dct[key] = rec
	return rec


func _crater_real(px: float, py: float, pz: float, cell: float, mask: int, seed: int, s: float, density: float, depth_scale: float, cache: Dictionary) -> float:
	var fade := smoothstep(2.0 * s, 6.0 * s, cell * 0.2)
	if fade <= 0.0 or far_crater_depth <= 0.0:
		return 0.0
	var qx := px / cell
	var qy := py / cell
	var qz := pz / cell
	var fx := floorf(qx)
	var fy := floorf(qy)
	var fz := floorf(qz)
	var i0x := int(fx)
	var i0y := int(fy)
	var i0z := int(fz)
	var sx := 1 if qx - fx >= 0.5 else -1
	var sy := 1 if qy - fy >= 0.5 else -1
	var sz := 1 if qz - fz >= 0.5 else -1
	var acc := 0.0
	for a in 2:
		for b in 2:
			for c in 2:
				var rec := _creal_cell(i0x + a * sx, i0y + b * sy, i0z + c * sz, mask, seed, density, cache)
				if rec.is_empty():
					continue
				var dx: float = (qx - rec[0]) * cell
				var dy: float = (qy - rec[1]) * cell
				var dz: float = (qz - rec[2]) * cell
				var dlen := maxf(sqrt(dx * dx + dy * dy + dz * dz), 1e-4)
				var rad: float = cell * rec[3]
				var x := dlen / rad
				if x > 1.9:
					continue
				var dr: float = float(rec[4]) * depth_scale * far_crater_depth
				var t := (x - 1.0) / 0.3
				var f := 0.35 * dr * exp(-t * t)                                # raised rim
				if x < 1.0:
					f += dr * (x * x - 1.0)                                      # bowl
					if rec[5]:
						f += 0.45 * dr * exp(-(x * x) / 0.02)                    # central peak
				else:
					var u := clampf((x - 1.2) / 0.7, 0.0, 1.0)
					var sm := u * u * (3.0 - 2.0 * u)
					f += 0.10 * dr * pow(x, -3.0) * (1.0 - sm)                   # ejecta blanket
				acc += fade * rad * f
	return acc


# All large-scale relief (cells 256 m .. 16 km). Independent of detail_amount, like in the shader.
func _far_height(px: float, py: float, pz: float, s: float, cache: Dictionary) -> float:
	if far_amount <= 0.0:
		return 0.0
	var h := 0.0
	h += _crater_real(px, py, pz, 16384.0, 15, 101, s, far_crater_density * 0.6, 0.55, cache)
	h += _crater_real(px, py, pz, 8192.0, 31, 107, s, far_crater_density * 0.8, 0.7, cache)
	h += _crater_real(px, py, pz, 4096.0, 63, 113, s, far_crater_density, 0.85, cache)
	h += _crater_real(px, py, pz, 2048.0, 127, 127, s, far_crater_density, 1.0, cache)
	h += _und_c(px, py, pz, 4096.0, 63, 131, s, cache)
	h += _und_c(px, py, pz, 1024.0, 255, 137, s, cache)
	h += _und_c(px, py, pz, 512.0, 511, 139, s, cache)
	h += _und_c(px, py, pz, 256.0, 1023, 149, s, cache)
	return h * far_amount


# Total displacement height (metres, along the radial up). pa* / pb* are the vertex position plus the
# mesh origin's true position reduced mod 4096 / 262144 (same reduction the shader gets).
func _vtx_height(pax: float, pay: float, paz: float, pbx: float, pby: float, pbz: float, d: float, cache: Dictionary) -> float:
	if d >= 45000.0:                         # the shader skips displacement beyond ~40 km from the mesh centre
		return 0.0
	var s := maxf(d, detail_near_m) * _spread
	var h := 0.0
	h += _craters(pbx, pby, pbz, 1024.0, 255, 11, s, cache)
	h += _craters(pbx, pby, pbz, 128.0, 2047, 23, s, cache)
	h += _bumps(pax, pay, paz, 16.0, 255, 31, s, cache)
	h += _bumps(pax, pay, paz, 4.0, 1023, 47, s, cache)
	h += _und_c(pbx, pby, pbz, 128.0, 2047, 59, s, cache)
	h += _und_c(pbx, pby, pbz, 32.0, 8191, 71, s, cache)
	h += _und_c(pax, pay, paz, 8.0, 511, 83, s, cache)
	h += _und_c(pax, pay, paz, 2.0, 2047, 97, s, cache)
	return h * detail_amount + _far_height(pbx, pby, pbz, s, cache)


# A mesh vertex (relative to the mesh origin at true position ox,oy,oz) pushed along the radial up.
func _displaced(v: Vector3, ox: float, oy: float, oz: float, cache: Dictionary) -> Vector3:
	var h := _vtx_height(
		fposmod(ox, 4096.0) + v.x, fposmod(oy, 4096.0) + v.y, fposmod(oz, 4096.0) + v.z,
		fposmod(ox, 262144.0) + v.x, fposmod(oy, 262144.0) + v.y, fposmod(oz, 262144.0) + v.z,
		v.length(), cache)
	var tx := ox + v.x
	var ty := oy + v.y
	var tz := oz + v.z
	var l := sqrt(tx * tx + ty * ty + tz * tz)
	return v + Vector3(tx / l, ty / l, tz / l) * h


# Displacement at a true position (used to place the spawn point on the displaced ground).
func _detail_height_at(px: float, py: float, pz: float) -> float:
	return _vtx_height(fposmod(px, 4096.0), fposmod(py, 4096.0), fposmod(pz, 4096.0),
		fposmod(px, 262144.0), fposmod(py, 262144.0), fposmod(pz, 262144.0), 0.0, {})


func _setup_terrain_detail() -> void:
	_detail_on = terrain_detail and detail_amount > 0.0 and _detail_mat != null
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("vtx_amount", detail_amount if _detail_on else 0.0)
	_detail_mat.set_shader_parameter("vtx_slope", detail_slope)
	_detail_mat.set_shader_parameter("vtx_bumps", detail_bumps)
	_detail_mat.set_shader_parameter("vtx_bump_density", detail_bump_density)
	_detail_mat.set_shader_parameter("vtx_crater_depth", detail_craters)
	_detail_mat.set_shader_parameter("vtx_crater_density", detail_crater_density)
	_detail_mat.set_shader_parameter("vtx_first_ring", first_ring_m)
	_detail_mat.set_shader_parameter("vtx_near", detail_near_m)
	_detail_mat.set_shader_parameter("vtx_spread", _spread)
	_detail_mat.set_shader_parameter("vtx_far_amount", far_amount)
	_detail_mat.set_shader_parameter("vtx_far_crater_density", far_crater_density)
	_detail_mat.set_shader_parameter("vtx_far_crater_depth", far_crater_depth)


# The shader needs the mesh origin's true position (set whenever a new mesh is swapped in).
func _update_mesh_origin_offsets() -> void:
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("vmo_a", Vector3(fposmod(_o[0], 4096.0), fposmod(_o[1], 4096.0), fposmod(_o[2], 4096.0)))
	_detail_mat.set_shader_parameter("vmo_b", Vector3(fposmod(_o[0], 262144.0), fposmod(_o[1], 262144.0), fposmod(_o[2], 262144.0)))
	_detail_mat.set_shader_parameter("vmo_full", Vector3(_o[0], _o[1], _o[2]))


# The shader fades displacement by distance from the PLAYER (not the mesh centre), so a mesh
# rebuild does not change the ground you are standing on. It needs the player in mesh-local space.
func _update_player_local(tx: float, ty: float, tz: float) -> void:
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("vtx_player", Vector3(tx - _o[0], ty - _o[1], tz - _o[2]))


func _apply(res: Dictionary) -> void:
	var arrays := []; arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = res.verts
	arrays[Mesh.ARRAY_NORMAL] = res.normals
	arrays[Mesh.ARRAY_INDEX] = res.idxs
	if res.cols.size() > 0:
		arrays[Mesh.ARRAY_COLOR] = res.cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mi.mesh = m
	_shape.set_faces(res.faces)
	_o = res.o
	_update_mesh_origin_offsets()


# The shader generates fine detail in TRUE planet space. Hand it the engine origin's true
# position, reduced here in doubles so float32 stays precise on the GPU.
func _update_detail_offsets() -> void:
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("off_a", Vector3(fposmod(_off[0], 4096.0), fposmod(_off[1], 4096.0), fposmod(_off[2], 4096.0)))
	_detail_mat.set_shader_parameter("off_b", Vector3(fposmod(_off[0], 262144.0), fposmod(_off[1], 262144.0), fposmod(_off[2], 262144.0)))
	_detail_mat.set_shader_parameter("off_full", Vector3(_off[0], _off[1], _off[2]))


# Topography -> albedo. Instead of the color map, the shader derives surface darkness from the
# heightmap using trends measured by NASA's LRO / LOLA (see moon_surface.gdshader). That needs the
# heightmap on the GPU, plus the vertical exaggeration of this particular heightmap so slopes and
# elevations can be evaluated in real kilometres.
func _setup_topo_albedo() -> void:
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("use_topo_albedo", 0.0)
	if not topo_albedo:
		return
	var img := Image.create_from_data(_w, _h, false, Image.FORMAT_RF, _data.to_byte_array())
	img.generate_mipmaps()
	_height_tex = ImageTexture.create_from_image(img)
	var km_per_unit_raw := REAL_RADIUS_KM / _mean
	var relief_km := (_rmax - _rmin) * km_per_unit_raw
	var exaggeration := maxf(relief_km / LOLA_RELIEF_KM, 0.1)
	_detail_mat.set_shader_parameter("height_tex", _height_tex)
	_detail_mat.set_shader_parameter("h_mean", _mean)
	_detail_mat.set_shader_parameter("km_per_unit", km_per_unit_raw / exaggeration)
	_detail_mat.set_shader_parameter("tex_size", Vector2(_w, _h))
	_detail_mat.set_shader_parameter("texel_m", _texel_m)
	_detail_mat.set_shader_parameter("use_topo_albedo", 1.0)


func _default_material() -> Material:
	if use_detail_shader:
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/moon_surface.gdshader")
		sm.set_shader_parameter("use_vertex_color", 1.0 if _has_color else 0.0)
		return sm
	var mat := StandardMaterial3D.new()
	mat.roughness = 1.0
	if _has_color:
		mat.albedo_color = Color.WHITE
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
	else:
		mat.albedo_color = Color(0.55, 0.55, 0.53)
	return mat
