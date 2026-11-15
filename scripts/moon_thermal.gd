class_name MoonThermal
extends Node
## Lunar surface temperature for Godot 4.2+.
##
## Layers of realism, from the data outward:
##  1. Sun geometry: lunar day (29.53 d), 1.54 deg axial tilt, orbit-distance flux swing.
##  2. 1D regolith heat diffusion per probe (Hayne et al. 2017 / Diviner-calibrated
##     density, conductivity, heat capacity) with Apollo heat flow at the bottom.
##  3. Real NASA LRO Diviner frames (output of moon_layers.py temp-data) sampled in
##     space and local lunar hour, optionally blended with the model.
##  4. Lumped heat balance for your rovers/habitats (sun, ground IR, heater, radiator).
##
## Axes: Godot X = east, Y = up, -Z = north.
## Add as an autoload or a child node, then call add_probe() during a loading screen
## (each new latitude runs a short spin-up).

signal hazard_changed(probe_id: StringName, hazard: int)
signal equipment_alarm(equipment_id: StringName, too_hot: bool)
signal stepped(sim_time_s: float)

enum Hazard { NOMINAL, COLD, FRIGID, HOT, SCORCHING }

# --- constants from NASA / Diviner / Apollo literature ---------------------------
const STEFAN_BOLTZMANN := 5.670374e-8
const SOLAR_CONSTANT := 1361.0                 # W/m^2 at 1 AU
const SYNODIC_DAY_S := 29.530588 * 86400.0     # sunrise to sunrise
const YEAR_S := 365.2422 * 86400.0
const OBLIQUITY_DEG := 1.54                    # spin-axis tilt to the ecliptic
const SUN_DIST_ECC := 0.0167                   # Earth-Moon system orbit eccentricity
const SURFACE_EMISSIVITY := 0.95
const ALBEDO_A := 0.045                        # incidence-angle terms, Vasavada et al. 2012
const ALBEDO_B := 0.14
const HEAT_FLOW := 0.018                       # W/m^2 interior heat flux
const REG_K_SURFACE := 7.4e-4                  # W/m/K, top of regolith
const REG_K_DEEP := 3.4e-3                     # W/m/K, below ~0.3 m
const REG_RHO_SURFACE := 1100.0                # kg/m^3
const REG_RHO_DEEP := 1800.0
const REG_H_SCALE := 0.06                      # m, e-folding depth of the density change
const REG_CHI := 2.7                           # radiative conduction term
const CP_COEF := [-3.6125, 2.7431, 2.3616e-3, -1.2340e-5, 8.9093e-9]   # cp(T) J/kg/K
const COLDEST_K := 25.0                        # Diviner minimum, permanently shadowed crater

# --- tuning ------------------------------------------------------------------------
@export var time_scale: float = 2125.0          # sim s per real s (1 lunar day = ~20 min)
@export var subsolar_lon_start_deg: float = 0.0 # sun is overhead at this longitude at t=0
@export_range(0.0, 1.0) var season_phase: float = 0.0
@export var layer_count: int = 24
@export var first_layer_m: float = 0.002
@export var layer_growth: float = 1.2           # 24 layers reach ~0.8 m
@export var step_s: float = 300.0               # implicit solver step, sim seconds
@export var max_substeps_per_frame: int = 48
@export var spin_up_days: float = 3.0
@export var running: bool = true
@export var frigid_k: float = 150.0
@export var cold_k: float = 230.0
@export var hot_k: float = 340.0
@export var scorching_k: float = 380.0

var sim_time_s: float = 0.0
var diviner: DivinerFrames = null

var _probes: Dictionary = {}
var _equipment: Dictionary = {}
var _profile_cache: Dictionary = {}
var _pending_s: float = 0.0


# ================================================================== solar geometry
static func specific_heat(t: float) -> float:
	var c: Array = CP_COEF
	return c[0] + t * (c[1] + t * (c[2] + t * (c[3] + t * c[4])))


static func albedo(a0: float, cos_inc: float) -> float:
	var theta := rad_to_deg(acos(clampf(cos_inc, 0.0, 1.0)))
	return a0 + ALBEDO_A * pow(theta / 45.0, 3.0) + ALBEDO_B * pow(theta / 90.0, 8.0)


func local_hour(lon_deg: float) -> float:
	return fposmod(12.0 + (lon_deg - subsolar_lon_start_deg) / 15.0
			+ 24.0 * sim_time_s / SYNODIC_DAY_S, 24.0)


func solar_declination_rad() -> float:
	var y := fposmod(sim_time_s / YEAR_S + season_phase, 1.0)
	return deg_to_rad(OBLIQUITY_DEG) * sin(TAU * y)


func solar_flux() -> float:
	var y := fposmod(sim_time_s / YEAR_S + season_phase, 1.0)
	return SOLAR_CONSTANT * (1.0 + 2.0 * SUN_DIST_ECC * cos(TAU * y))


func sun_direction(lat_deg: float, hour: float) -> Vector3:
	var phi := deg_to_rad(lat_deg)
	var dec := solar_declination_rad()
	var h := deg_to_rad((hour - 12.0) * 15.0)
	var east := -cos(dec) * sin(h)
	var north := cos(phi) * sin(dec) - sin(phi) * cos(dec) * cos(h)
	var up := sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)
	return Vector3(east, up, -north).normalized()


# ================================================================== regolith column
class Column:
	var n: int
	var dz := PackedFloat64Array()
	var zc := PackedFloat64Array()
	var rho := PackedFloat64Array()
	var kc := PackedFloat64Array()
	var temp := PackedFloat64Array()
	var _k := PackedFloat64Array()
	var _g := PackedFloat64Array()
	var _a := PackedFloat64Array()
	var _b := PackedFloat64Array()
	var _c := PackedFloat64Array()
	var _d := PackedFloat64Array()
	var _cp := PackedFloat64Array()
	var _dp := PackedFloat64Array()

	func _init(count: int, first: float, growth: float, t_init: float) -> void:
		n = count
		dz.resize(n)
		zc.resize(n)
		rho.resize(n)
		kc.resize(n)
		temp.resize(n)
		_k.resize(n)
		_g.resize(n)
		_a.resize(n)
		_b.resize(n)
		_c.resize(n)
		_d.resize(n)
		_cp.resize(n)
		_dp.resize(n)
		var depth := 0.0
		for i in n:
			dz[i] = first * pow(growth, i)
			zc[i] = depth + dz[i] * 0.5
			depth += dz[i]
			var e := exp(-zc[i] / MoonThermal.REG_H_SCALE)
			rho[i] = MoonThermal.REG_RHO_DEEP - (MoonThermal.REG_RHO_DEEP - MoonThermal.REG_RHO_SURFACE) * e
			kc[i] = MoonThermal.REG_K_DEEP - (MoonThermal.REG_K_DEEP - MoonThermal.REG_K_SURFACE) * e
			temp[i] = t_init

	## Backward-Euler step with a linearised radiative surface boundary.
	func step(dt: float, absorbed_solar_wm2: float) -> void:
		var sig_e := MoonThermal.STEFAN_BOLTZMANN * MoonThermal.SURFACE_EMISSIVITY
		for i in n:
			_k[i] = kc[i] * (1.0 + MoonThermal.REG_CHI * pow(temp[i] / 350.0, 3.0))
		for i in n - 1:
			var ki := 2.0 * _k[i] * _k[i + 1] / (_k[i] + _k[i + 1])
			_g[i] = ki / (0.5 * (dz[i] + dz[i + 1]))
		for i in n:
			var cap := rho[i] * MoonThermal.specific_heat(temp[i]) * dz[i] / dt
			_b[i] = cap
			_d[i] = cap * temp[i]
			_a[i] = 0.0
			_c[i] = 0.0
			if i > 0:
				_b[i] += _g[i - 1]
				_a[i] = -_g[i - 1]
			if i < n - 1:
				_b[i] += _g[i]
				_c[i] = -_g[i]
		var t0 := temp[0]
		_b[0] += 4.0 * sig_e * pow(t0, 3.0)
		_d[0] += absorbed_solar_wm2 + 3.0 * sig_e * pow(t0, 4.0)
		_d[n - 1] += MoonThermal.HEAT_FLOW
		_cp[0] = _c[0] / _b[0]
		_dp[0] = _d[0] / _b[0]
		for i in range(1, n):
			var m := _b[i] - _a[i] * _cp[i - 1]
			_cp[i] = _c[i] / m
			_dp[i] = (_d[i] - _a[i] * _dp[i - 1]) / m
		temp[n - 1] = _dp[n - 1]
		for i in range(n - 2, -1, -1):
			temp[i] = _dp[i] - _cp[i] * temp[i + 1]


# ================================================================== probes
class Probe:
	var id: StringName
	var lat_deg := 0.0
	var lon_deg := 0.0
	var albedo0 := 0.07
	var normal := Vector3.UP
	var shadow_fn := Callable()      # func(sun_dir: Vector3) -> bool, true = shadowed by terrain
	var column: Column
	var lit := false
	var absorbed_wm2 := 0.0
	var hazard := 0


func add_probe(id: StringName, lat_deg: float, lon_deg: float, albedo0: float = 0.07,
		normal: Vector3 = Vector3.UP, shadow_fn: Callable = Callable()) -> void:
	var p := Probe.new()
	p.id = id
	p.lat_deg = lat_deg
	p.lon_deg = lon_deg
	p.albedo0 = albedo0
	p.normal = normal.normalized()
	p.shadow_fn = shadow_fn
	p.column = _make_column(lat_deg, albedo0)
	_probes[id] = p


func set_probe_normal(id: StringName, normal: Vector3) -> void:
	if _probes.has(id):
		_probes[id].normal = normal.normalized()


func _make_column(lat_deg: float, albedo0: float) -> Column:
	var t_deep := 250.0 * pow(maxf(cos(deg_to_rad(lat_deg)), 0.05), 0.25)
	var col := Column.new(layer_count, first_layer_m, layer_growth, t_deep)
	var key := Vector2i(roundi(lat_deg), roundi(albedo0 * 100.0))
	if _profile_cache.has(key):
		col.temp = _profile_cache[key].duplicate()
		return col
	var dt := 1800.0
	var steps := int(spin_up_days * SYNODIC_DAY_S / dt)
	var dec := solar_declination_rad()
	var phi := deg_to_rad(lat_deg)
	var flux := solar_flux()
	for s in steps:
		var h := TAU * fposmod(float(s) * dt / SYNODIC_DAY_S, 1.0)
		var up := sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)
		var solar := 0.0
		if up > 0.0:
			solar = flux * (1.0 - albedo(albedo0, up)) * up
		col.step(dt, solar)
	_profile_cache[key] = col.temp.duplicate()
	return col


# ================================================================== simulation loop
func _process(delta: float) -> void:
	if not running:
		return
	_pending_s += delta * time_scale
	var done := 0
	while _pending_s >= step_s and done < max_substeps_per_frame:
		_advance(step_s)
		_pending_s -= step_s
		done += 1
	if done == max_substeps_per_frame:
		_pending_s = 0.0          # drop backlog instead of spiralling


func _advance(dt: float) -> void:
	sim_time_s += dt
	var flux := solar_flux()
	for p: Probe in _probes.values():
		var sun := sun_direction(p.lat_deg, local_hour(p.lon_deg))
		var cos_inc := maxf(p.normal.dot(sun), 0.0)
		var lit := sun.y > 0.0 and cos_inc > 0.0
		if lit and p.shadow_fn.is_valid():
			lit = not bool(p.shadow_fn.call(sun))
		p.lit = lit
		p.absorbed_wm2 = 0.0
		if lit:
			p.absorbed_wm2 = flux * (1.0 - albedo(p.albedo0, cos_inc)) * cos_inc
		p.column.step(dt, p.absorbed_wm2)
		var hz := _classify(p.column.temp[0])
		if hz != p.hazard:
			p.hazard = hz
			hazard_changed.emit(p.id, hz)
	for e: Equipment in _equipment.values():
		if _probes.has(e.probe_id):
			var p2: Probe = _probes[e.probe_id]
			_step_equipment(e, p2, dt, sun_direction(p2.lat_deg, local_hour(p2.lon_deg)), flux)
	stepped.emit(sim_time_s)


func _classify(t: float) -> int:
	if t >= scorching_k:
		return Hazard.SCORCHING
	if t >= hot_k:
		return Hazard.HOT
	if t <= frigid_k:
		return Hazard.FRIGID
	if t <= cold_k:
		return Hazard.COLD
	return Hazard.NOMINAL


# ================================================================== equipment
class Equipment:
	var id: StringName
	var probe_id: StringName
	var mass_kg := 100.0
	var cp_j_kgk := 900.0
	var area_m2 := 2.0
	var absorptivity := 0.25         # white paint ~0.2, bare metal ~0.4
	var emissivity := 0.85
	var internal_w := 60.0
	var heater_w := 80.0
	var heater_on_k := 260.0
	var max_k := 350.0
	var min_k := 220.0
	var temp_k := 280.0
	var heater_active := false
	var alarm := 0                   # 1 hot, -1 cold, 0 ok


func add_equipment(id: StringName, probe_id: StringName, props: Dictionary = {}) -> void:
	var e := Equipment.new()
	e.id = id
	e.probe_id = probe_id
	for k in props:
		e.set(k, props[k])
	_equipment[id] = e


func _step_equipment(e: Equipment, p: Probe, dt: float, sun: Vector3, flux: float) -> void:
	var sun_w := 0.0
	if p.lit:
		sun_w = e.absorptivity * flux * e.area_m2 * (0.25 + 0.5 * maxf(sun.y, 0.0))
	e.heater_active = e.temp_k < e.heater_on_k or (e.heater_active and e.temp_k < e.heater_on_k + 8.0)
	var sig := STEFAN_BOLTZMANN * e.emissivity * e.area_m2
	var heat := e.internal_w + sun_w + 0.4 * sig * pow(p.column.temp[0], 4.0)   # 40% ground view
	if e.heater_active:
		heat += e.heater_w
	var net := heat - sig * pow(e.temp_k, 4.0)
	var cap := e.mass_kg * e.cp_j_kgk
	e.temp_k += dt * net / (cap + dt * 4.0 * sig * pow(e.temp_k, 3.0))
	var state := 0
	if e.temp_k > e.max_k:
		state = 1
	elif e.temp_k < e.min_k:
		state = -1
	if state != e.alarm:
		e.alarm = state
		if state != 0:
			equipment_alarm.emit(e.id, state == 1)


# ================================================================== queries
func surface_temp_k(id: StringName) -> float:
	return _probes[id].column.temp[0] if _probes.has(id) else NAN


func temp_at_depth_k(id: StringName, depth_m: float) -> float:
	if not _probes.has(id):
		return NAN
	var c: Column = _probes[id].column
	if depth_m <= c.zc[0]:
		return c.temp[0]
	for i in range(1, c.n):
		if depth_m <= c.zc[i]:
			var f := (depth_m - c.zc[i - 1]) / (c.zc[i] - c.zc[i - 1])
			return lerpf(c.temp[i - 1], c.temp[i], f)
	return c.temp[c.n - 1]


func equipment_temp_k(id: StringName) -> float:
	return _equipment[id].temp_k if _equipment.has(id) else NAN


func hazard_of(id: StringName) -> int:
	return _probes[id].hazard if _probes.has(id) else Hazard.NOMINAL


func is_sunlit(id: StringName) -> bool:
	return _probes.has(id) and _probes[id].lit


func sun_elevation_deg(id: StringName) -> float:
	if not _probes.has(id):
		return NAN
	var p: Probe = _probes[id]
	return rad_to_deg(asin(clampf(sun_direction(p.lat_deg, local_hour(p.lon_deg)).y, -1.0, 1.0)))


# ================================================================== NASA Diviner frames
## Loads the frames written by moon_layers.py (temp-data): <name>_temp.json plus
## <file>_16.png per local hour. Frames are 16-bit PNGs; if the engine reduces them to
## 8 bit the temperature resolution is about 1.6 K, fine for gameplay.
## Keep the files outside res:// (e.g. user://) or mark them "do not import".
class DivinerFrames:
	var hours := PackedFloat64Array()
	var images: Array[Image] = []
	var k_max := 400.0

	func load_from_json(json_path: String) -> bool:
		var f := FileAccess.open(json_path, FileAccess.READ)
		if f == null:
			return false
		var data = JSON.parse_string(f.get_as_text())
		if typeof(data) != TYPE_DICTIONARY:
			return false
		var rx := RegEx.create_from_string("\\*\\s*([0-9.]+)")
		var m := rx.search(str(data.get("decode_16bit", "")))
		if m:
			k_max = float(m.get_string(1))
		var frames: Array = data.get("frames", [])
		frames.sort_custom(func(a, b): return float(a["local_hour"]) < float(b["local_hour"]))
		var base := json_path.get_base_dir()
		for fr in frames:
			var img := Image.load_from_file(base.path_join(str(fr["file"]) + "_16.png"))
			if img == null:
				continue
			hours.append(float(fr["local_hour"]))
			images.append(img)
		return images.size() > 0

	## uv: (0,0) = north-west corner of the region, (1,1) = south-east.
	func sample_k(uv: Vector2, hour: float) -> float:
		var n := hours.size()
		if n == 0:
			return NAN
		var h := fposmod(hour, 24.0)
		var i1 := 0
		while i1 < n and hours[i1] <= h:
			i1 += 1
		var i0 := (i1 - 1 + n) % n
		i1 = i1 % n
		var span := fposmod(hours[i1] - hours[i0], 24.0)
		if span == 0.0:
			span = 24.0
		var w := fposmod(h - hours[i0], 24.0) / span
		return lerpf(_bilinear(images[i0], uv), _bilinear(images[i1], uv), w)

	func _bilinear(img: Image, uv: Vector2) -> float:
		var w := img.get_width()
		var hgt := img.get_height()
		var fx := clampf(uv.x, 0.0, 1.0) * (w - 1)
		var fy := clampf(uv.y, 0.0, 1.0) * (hgt - 1)
		var x0 := mini(int(floor(fx)), w - 2)
		var y0 := mini(int(floor(fy)), hgt - 2)
		var tx := fx - x0
		var ty := fy - y0
		var a := lerpf(img.get_pixel(x0, y0).r, img.get_pixel(x0 + 1, y0).r, tx)
		var b := lerpf(img.get_pixel(x0, y0 + 1).r, img.get_pixel(x0 + 1, y0 + 1).r, tx)
		return lerpf(a, b, ty) * k_max


func load_diviner(json_path: String) -> bool:
	diviner = DivinerFrames.new()
	if not diviner.load_from_json(json_path):
		diviner = null
		return false
	return true


## Real data at map scale, blended with the physics model in radiance space (T^4).
## data_weight 1 = pure Diviner, 0 = pure model.
func hybrid_surface_k(id: StringName, uv: Vector2, data_weight: float = 0.5) -> float:
	var model := surface_temp_k(id)
	if diviner == null or is_nan(model):
		return model
	var data := diviner.sample_k(uv, local_hour(_probes[id].lon_deg))
	if is_nan(data):
		return model
	var w := clampf(data_weight, 0.0, 1.0)
	return pow(w * pow(data, 4.0) + (1.0 - w) * pow(model, 4.0), 0.25)
