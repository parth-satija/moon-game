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

@export_group("Mesh LOD")
@export var first_ring_m := 3.0           # distance of the first ring from the player
@export var ring_growth := 1.05             # ~ 2*PI/segments keeps triangles roughly square
@export var segments := 128
@export var max_arc := PI                   # PI = whole globe
@export var rebuild_distance_m := 25.0

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
@export var detail_collision_radius_m := 300.0      # displacement is mirrored into collision out to here

var gravity_vector := Vector3.DOWN * 1.62
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


func _ready() -> void:
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
	_apply(_build_job(_off[0], _off[1], _off[2]))      # first mesh, synchronous


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
	if not _thread.is_started():
		var dx: float = tx - _o[0]; var dy: float = ty - _o[1]; var dz: float = tz - _o[2]
		if sqrt(dx * dx + dy * dy + dz * dz) > rebuild_distance_m:
			_thread.start(_build_job.bind(tx, ty, tz))

	var pos := Vector3(_o[0] - _off[0], _o[1] - _off[1], _o[2] - _off[2])
	_mi.position = pos
	_body.position = pos


func _exit_tree() -> void:
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
func _sample_m_lod(dir: Vector3, lod: float) -> float:
	var maxl := _h_mips.size()
	if lod <= 0.0 or maxl == 0:
		return _sample_m(dir)
	var lc := clampf(lod, 0.0, float(maxl))
	var l0 := int(floor(lc))
	var l1 := mini(l0 + 1, maxl)
	var rm := _rm_level(dir, l0)
	if l1 != l0:
		rm = lerpf(rm, _rm_level(dir, l1), lc - float(l0))
	return planet_radius_m * (1.0 + (rm / _mean - 1.0) * height_exaggeration)


func _build_job(cx: float, cy: float, cz: float) -> Dictionary:
	var cl := sqrt(cx * cx + cy * cy + cz * cz)
	var n := Vector3(cx / cl, cy / cl, cz / cl)
	var ref := Vector3.UP if absf(n.y) < 0.99 else Vector3.RIGHT
	var t := ref.cross(n).normalized()
	var b := n.cross(t)
	var rc := _sample_m(n)                       # mesh origin sits on the surface at n

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
			var r := _sample_m_lod(dir, lods[i])
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


# Total displacement height (metres, along the radial up). pa* / pb* are the vertex position plus the
# mesh origin's true position reduced mod 4096 / 262144 (same reduction the shader gets).
func _vtx_height(pax: float, pay: float, paz: float, pbx: float, pby: float, pbz: float, d: float, cache: Dictionary) -> float:
	if d >= 6000.0:
		return 0.0
	var s := maxf(d, first_ring_m) * _spread
	var h := 0.0
	h += _craters(pbx, pby, pbz, 1024.0, 255, 11, s, cache)
	h += _craters(pbx, pby, pbz, 128.0, 2047, 23, s, cache)
	h += _bumps(pax, pay, paz, 16.0, 255, 31, s, cache)
	h += _bumps(pax, pay, paz, 4.0, 1023, 47, s, cache)
	h += _und(pbx, pby, pbz, 128.0, 2047, 59, s)
	h += _und(pbx, pby, pbz, 32.0, 8191, 71, s)
	h += _und(pax, pay, paz, 8.0, 511, 83, s)
	h += _und(pax, pay, paz, 2.0, 2047, 97, s)
	return h * detail_amount


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
	_detail_mat.set_shader_parameter("vtx_spread", _spread)


# The shader needs the mesh origin's true position (set whenever a new mesh is swapped in).
func _update_mesh_origin_offsets() -> void:
	if _detail_mat == null:
		return
	_detail_mat.set_shader_parameter("vmo_a", Vector3(fposmod(_o[0], 4096.0), fposmod(_o[1], 4096.0), fposmod(_o[2], 4096.0)))
	_detail_mat.set_shader_parameter("vmo_b", Vector3(fposmod(_o[0], 262144.0), fposmod(_o[1], 262144.0), fposmod(_o[2], 262144.0)))
	_detail_mat.set_shader_parameter("vmo_full", Vector3(_o[0], _o[1], _o[2]))


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