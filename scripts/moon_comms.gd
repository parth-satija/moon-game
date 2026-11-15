class_name MoonComms
extends Node
## Lunar radio network for Godot 4.2+.
##
##  1. Terrain: real LROC GLD100 elevations (the *_height16.r16 + *_settings.json files from
##     moon_pipeline.py) with lunar curvature (R = 1737.4 km).
##  2. Node-to-node links: free-space path loss + knife-edge diffraction on the worst
##     obstacle (Fresnel parameter, ITU-R P.526), thermal noise (kTB + noise figure),
##     Shannon-limited data rate, signal bars, light-time latency.
##  3. Direct-to-Earth: sub-Earth point wanders with libration (7.9 deg lon, 6.7 deg lat),
##     Earth distance follows the eccentric orbit (363,000-405,000 km, 1.2-1.35 s one way),
##     terrain horizon mask along the Earth azimuth.
##  4. Network: widest-path routing from every node to Earth through relays.
##  5. Pre-baked coverage maps from moon_layers.py comms for HUD lookups.
##  6. Optional coupling with MoonThermal: hot radios lose transmit power.
##
## Axes: Godot X = east, Y = up, -Z = north. Distances in metres unless named otherwise.

signal route_changed(node_id: StringName, connected: bool)
signal network_updated

enum Kind { SURFACE, ROVER, RELAY }

const C_LIGHT := 299792458.0
const R_MOON_M := 1737400.0
const LN10 := 2.302585092994046
const NOISE_FLOOR_DBM_HZ := -174.0            # kT at 290 K
const EARTH_MEAN_DIST_KM := 384400.0
const EARTH_ECC := 0.0549
const ANOMALISTIC_MONTH_S := 27.554550 * 86400.0
const DRACONIC_MONTH_S := 27.212221 * 86400.0
const LIB_LON_MAX_DEG := 7.9
const LIB_LAT_MAX_DEG := 6.7

@export var thermal: MoonThermal                # optional: shares sim time, applies heat derating
@export var time_scale: float = 2125.0          # used only when no thermal node is assigned
@export var freq_hz: float = 2.2e9              # S-band
@export var update_interval_s: float = 0.5
@export var max_link_km: float = 150.0
@export var max_samples: int = 1500
@export var impl_loss_db: float = 3.0           # modem loss against the Shannon limit
@export var min_usable_snr_db: float = 0.0
@export var bar_thresholds_db: Array[float] = [3.0, 9.0, 15.0, 21.0]
@export var processing_delay_s: float = 0.005   # per hop
@export var earth_station_gain_dbi: float = 56.0   # ~34 m dish at S-band
@export var earth_station_nf_db: float = 1.0
@export var earth_horizon_scan_km: float = 30.0
@export var earth_clearance_deg: float = 0.5
@export var derate_start_k: float = 330.0
@export var derate_db_per_k: float = 0.15
@export var region_center_world: Vector3 = Vector3.ZERO
@export var world_units_per_meter: float = 1.0

var sim_time_s: float = 0.0
var terrain: Terrain = null
var signal_map: SignalMap = null

var _radios: Dictionary = {}
var _links: Dictionary = {}
var _earth_links: Dictionary = {}
var _adj: Dictionary = {}
var _routes: Dictionary = {}
var _was_connected: Dictionary = {}
var _acc: float = 0.0


# ================================================================== data classes
class Radio:
	var id: StringName
	var kind := 0
	var pos := Vector3.ZERO
	var lat_deg := 0.0
	var lon_deg := 0.0
	var mast_m := 2.0
	var tx_dbm := 30.0
	var gain_dbi := 3.0
	var noise_fig_db := 3.0
	var bandwidth_hz := 5.0e6
	var max_rate_bps := 10.0e6
	var dte_capable := false
	var dte_tx_dbm := 40.0
	var dte_gain_dbi := 20.0
	var dte_bandwidth_hz := 1.0e6
	var dte_max_rate_bps := 5.0e6
	var equipment_id: StringName = &""
	var derate_db := 0.0
	var online := true


class Link:
	var a: StringName
	var b: StringName
	var dist_m := 0.0
	var los := true
	var fspl_db := 0.0
	var diff_db := 0.0
	var rx_dbm := -300.0
	var snr_db := -100.0
	var rate_bps := 0.0
	var latency_s := 0.0
	var bars := 0


## Elevation grid from moon_pipeline.py: <name>_settings.json + <name>_height16.r16.
## The raw 16-bit file is used (not the PNG) so elevations keep full precision.
class Terrain:
	var data := PackedFloat32Array()
	var n := 0
	var lo := 0.0
	var hi := 1.0
	var px_m := 100.0
	var center_lat := 0.0
	var center_lon := 0.0

	func load_from(settings_json: String, r16_path: String) -> bool:
		var f := FileAccess.open(settings_json, FileAccess.READ)
		if f == null:
			return false
		var d = JSON.parse_string(f.get_as_text())
		if typeof(d) != TYPE_DICTIONARY:
			return false
		lo = float(d["elevation_min_m"])
		hi = float(d["elevation_max_m"])
		px_m = float(d["grid_spacing_m"])
		n = int(str(d["grid"]).split("x")[0])
		center_lat = float(d["center_lat_lon"][0])
		center_lon = float(d["center_lat_lon"][1])
		var raw := FileAccess.open(r16_path, FileAccess.READ)
		if raw == null:
			return false
		var buf := raw.get_buffer(n * n * 2)
		if buf.size() < n * n * 2:
			return false
		data.resize(n * n)
		for i in n * n:
			data[i] = buf.decode_u16(i * 2) / 65535.0
		return true

	## Elevation in metres above the 1737.4 km reference sphere; NAN outside the region.
	## east/north are metres from the region centre.
	func height_m(east: float, north: float) -> float:
		var half := px_m * (n - 1) * 0.5
		var fx := (east + half) / px_m
		var fy := (half - north) / px_m
		if fx < 0.0 or fy < 0.0 or fx > n - 1 or fy > n - 1:
			return NAN
		var x0 := mini(int(floor(fx)), n - 2)
		var y0 := mini(int(floor(fy)), n - 2)
		var tx := fx - x0
		var ty := fy - y0
		var a := lerpf(data[y0 * n + x0], data[y0 * n + x0 + 1], tx)
		var b := lerpf(data[(y0 + 1) * n + x0], data[(y0 + 1) * n + x0 + 1], tx)
		return lo + lerpf(a, b, ty) * (hi - lo)


## Coverage rasters from moon_layers.py comms: <name>_signal16.png, _bars.png, _coverage.png.
class SignalMap:
	var signal_img: Image
	var bars_img: Image
	var cover_img: Image
	var lo_dbm := -130.0       # --map-lo
	var hi_dbm := -60.0        # --map-hi
	var region_size_m := 100800.0

	func load_from(dir: String, name: String) -> bool:
		signal_img = Image.load_from_file(dir.path_join(name + "_signal16.png"))
		bars_img = Image.load_from_file(dir.path_join(name + "_bars.png"))
		cover_img = Image.load_from_file(dir.path_join(name + "_coverage.png"))
		return signal_img != null and bars_img != null and cover_img != null

	func _px(img: Image, east: float, north: float) -> Color:
		var w := img.get_width()
		var fx := clampf((east / region_size_m + 0.5) * (w - 1), 0.0, w - 1)
		var fy := clampf((0.5 - north / region_size_m) * (w - 1), 0.0, w - 1)
		return img.get_pixel(int(round(fx)), int(round(fy)))

	func dbm_at(east: float, north: float) -> float:
		return lo_dbm + _px(signal_img, east, north).r * (hi_dbm - lo_dbm)

	func bars_at(east: float, north: float) -> int:
		return int(round(_px(bars_img, east, north).r * 255.0 / 63.0))

	func covered_at(east: float, north: float) -> bool:
		return _px(cover_img, east, north).r > 0.5


# ================================================================== setup
func load_terrain(settings_json: String, r16_path: String) -> bool:
	terrain = Terrain.new()
	if not terrain.load_from(settings_json, r16_path):
		terrain = null
		return false
	return true


func load_signal_map(dir: String, name: String, region_size_km: float) -> bool:
	signal_map = SignalMap.new()
	signal_map.region_size_m = region_size_km * 1000.0
	if not signal_map.load_from(dir, name):
		signal_map = null
		return false
	return true


## props can override any Radio field, e.g. {"mast_m": 12.0, "tx_dbm": 37.0}.
func add_radio(id: StringName, kind: int, world_pos: Vector3, props: Dictionary = {}) -> void:
	var r := Radio.new()
	r.id = id
	r.kind = kind
	match kind:
		Kind.SURFACE:
			r.mast_m = 10.0
			r.tx_dbm = 40.0
			r.gain_dbi = 8.0
			r.dte_capable = true
			r.dte_gain_dbi = 28.0
			r.dte_tx_dbm = 43.0
			r.dte_max_rate_bps = 20.0e6
			r.max_rate_bps = 20.0e6
		Kind.RELAY:
			r.mast_m = 15.0
			r.tx_dbm = 37.0
			r.gain_dbi = 6.0
			r.dte_capable = true
			r.dte_gain_dbi = 20.0
			r.dte_tx_dbm = 40.0
		Kind.ROVER:
			r.mast_m = 2.0
			r.tx_dbm = 30.0
			r.gain_dbi = 3.0
	for k in props:
		r.set(k, props[k])
	r.pos = world_pos
	_update_latlon(r)
	_radios[id] = r


func move_radio(id: StringName, world_pos: Vector3) -> void:
	if _radios.has(id):
		_radios[id].pos = world_pos
		_update_latlon(_radios[id])


func remove_radio(id: StringName) -> void:
	_radios.erase(id)


func set_online(id: StringName, online: bool) -> void:
	if _radios.has(id):
		_radios[id].online = online


# ================================================================== geometry helpers
func _local(world: Vector3) -> Vector2:
	var d := (world - region_center_world) / world_units_per_meter
	return Vector2(d.x, -d.z)                        # (east, north)


func _update_latlon(r: Radio) -> void:
	var e := _local(r.pos)
	var clat := terrain.center_lat if terrain else 0.0
	var clon := terrain.center_lon if terrain else 0.0
	r.lat_deg = clat + rad_to_deg(e.y / R_MOON_M)
	r.lon_deg = clon + rad_to_deg(e.x / (R_MOON_M * maxf(cos(deg_to_rad(r.lat_deg)), 0.01)))


func _raw(p: Vector2) -> float:
	if terrain == null:
		return 0.0
	var h := terrain.height_m(p.x, p.y)
	return 0.0 if is_nan(h) else h


## Elevation expressed in the tangent plane at the region centre, so straight 3D lines of
## sight are exact: z = (R + h) cos(r / R) - R.
func _ground(p: Vector2) -> float:
	return (R_MOON_M + _raw(p)) * cos(p.length() / R_MOON_M) - R_MOON_M


static func knife_edge_db(v: float) -> float:
	if v <= -0.78:
		return 0.0
	return maxf(6.9 + 20.0 * log(sqrt((v - 0.1) * (v - 0.1) + 1.0) + v - 0.1) / LN10, 0.0)


static func _db10(x: float) -> float:
	return 10.0 * log(maxf(x, 1e-30)) / LN10


func _noise_dbm(bw_hz: float, nf_db: float) -> float:
	return NOISE_FLOOR_DBM_HZ + _db10(bw_hz) + nf_db


func _rate_bps(snr_db: float, bw_hz: float, cap_bps: float) -> float:
	if snr_db < min_usable_snr_db:
		return 0.0
	var lin := pow(10.0, (snr_db - impl_loss_db) / 10.0)
	return minf(bw_hz * log(1.0 + lin) / log(2.0), cap_bps)


func _bars(snr_db: float) -> int:
	var b := 0
	for t in bar_thresholds_db:
		if snr_db >= t:
			b += 1
	return b


# ================================================================== link budgets
func evaluate_link(a: Radio, b: Radio) -> Link:
	var ln := Link.new()
	ln.a = a.id
	ln.b = b.id
	var pa := _local(a.pos)
	var pb := _local(b.pos)
	var za := _ground(pa) + a.mast_m
	var zb := _ground(pb) + b.mast_m
	var d := maxf(pa.distance_to(pb), 1.0)
	var dz := zb - za
	ln.dist_m = sqrt(d * d + dz * dz)
	var lam := C_LIGHT / freq_hz
	var step := terrain.px_m if terrain else 100.0
	var n := clampi(int(ceil(d / step)), 2, max_samples)
	var vmax := -INF
	for i in range(1, n):
		var t := float(i) / float(n)
		var h := _ground(pa.lerp(pb, t)) - (za + dz * t)
		var d1 := d * t
		var d2 := d - d1
		vmax = maxf(vmax, h * sqrt(2.0 * d / (lam * d1 * d2)))
	ln.los = vmax <= 0.0
	ln.fspl_db = 20.0 * log(maxf(4.0 * PI * ln.dist_m * freq_hz / C_LIGHT, 1.0)) / LN10
	ln.diff_db = knife_edge_db(vmax)
	var loss := ln.fspl_db + ln.diff_db
	var rx_ab := a.tx_dbm - a.derate_db + a.gain_dbi + b.gain_dbi - loss
	var rx_ba := b.tx_dbm - b.derate_db + b.gain_dbi + a.gain_dbi - loss
	var bw := minf(a.bandwidth_hz, b.bandwidth_hz)
	var snr_ab := rx_ab - _noise_dbm(bw, b.noise_fig_db)
	var snr_ba := rx_ba - _noise_dbm(bw, a.noise_fig_db)
	ln.rx_dbm = minf(rx_ab, rx_ba)
	ln.snr_db = minf(snr_ab, snr_ba)
	ln.rate_bps = _rate_bps(ln.snr_db, bw, minf(a.max_rate_bps, b.max_rate_bps))
	ln.bars = _bars(ln.snr_db)
	ln.latency_s = ln.dist_m / C_LIGHT + processing_delay_s
	return ln


# ================================================================== Earth
func earth_state(lat_deg: float, lon_deg: float) -> Dictionary:
	var lat_e := deg_to_rad(LIB_LAT_MAX_DEG * sin(TAU * sim_time_s / DRACONIC_MONTH_S))
	var lon_e := deg_to_rad(LIB_LON_MAX_DEG * sin(TAU * sim_time_s / ANOMALISTIC_MONTH_S))
	var phi := deg_to_rad(lat_deg)
	var dl := lon_e - deg_to_rad(lon_deg)
	var sin_el := sin(phi) * sin(lat_e) + cos(phi) * cos(lat_e) * cos(dl)
	var az := atan2(sin(dl) * cos(lat_e), cos(phi) * sin(lat_e) - sin(phi) * cos(lat_e) * cos(dl))
	var dist_km := EARTH_MEAN_DIST_KM * (1.0 - EARTH_ECC * cos(TAU * sim_time_s / ANOMALISTIC_MONTH_S))
	return {
		"elev_deg": rad_to_deg(asin(clampf(sin_el, -1.0, 1.0))),
		"az_deg": fposmod(rad_to_deg(az), 360.0),
		"dist_km": dist_km,
		"light_time_s": dist_km * 1000.0 / C_LIGHT,
	}


## Highest terrain angle above the local horizontal along an azimuth.
func _horizon_deg(r: Radio, az_deg: float) -> float:
	var p0 := _local(r.pos)
	var z0 := _raw(p0) + r.mast_m
	var dir := Vector2(sin(deg_to_rad(az_deg)), cos(deg_to_rad(az_deg)))
	var step := terrain.px_m if terrain else 100.0
	var best := -90.0
	var s := step
	while s <= earth_horizon_scan_km * 1000.0:
		var p := p0 + dir * s
		if terrain and is_nan(terrain.height_m(p.x, p.y)):
			break
		var rise := _raw(p) - z0 - s * s / (2.0 * R_MOON_M)    # drop-off from curvature
		best = maxf(best, rad_to_deg(atan2(rise, s)))
		s += step
	return best


func evaluate_earth_link(r: Radio) -> Link:
	var ln := Link.new()
	ln.a = r.id
	ln.b = &"EARTH"
	var es := earth_state(r.lat_deg, r.lon_deg)
	ln.dist_m = float(es["dist_km"]) * 1000.0
	ln.latency_s = float(es["light_time_s"])
	var elev: float = es["elev_deg"]
	if elev <= 0.0:
		ln.los = false
		return ln
	ln.los = elev > _horizon_deg(r, float(es["az_deg"])) + earth_clearance_deg
	if not ln.los:
		return ln
	ln.fspl_db = 20.0 * log(4.0 * PI * ln.dist_m * freq_hz / C_LIGHT) / LN10
	ln.rx_dbm = r.dte_tx_dbm - r.derate_db + r.dte_gain_dbi + earth_station_gain_dbi - ln.fspl_db
	ln.snr_db = ln.rx_dbm - _noise_dbm(r.dte_bandwidth_hz, earth_station_nf_db)
	ln.rate_bps = _rate_bps(ln.snr_db, r.dte_bandwidth_hz, r.dte_max_rate_bps)
	ln.bars = _bars(ln.snr_db)
	return ln


# ================================================================== network
func _process(delta: float) -> void:
	if thermal != null:
		sim_time_s = thermal.sim_time_s
	else:
		sim_time_s += delta * time_scale
	_acc += delta
	if _acc >= update_interval_s:
		_acc = 0.0
		update_network()


func update_network() -> void:
	if thermal != null:
		for r: Radio in _radios.values():
			if r.equipment_id != &"":
				var t := thermal.equipment_temp_k(r.equipment_id)
				if not is_nan(t):
					r.derate_db = clampf((t - derate_start_k) * derate_db_per_k, 0.0, 20.0)
	_links.clear()
	_earth_links.clear()
	_adj.clear()
	var ids: Array = _radios.keys()
	for i in ids.size():
		var a: Radio = _radios[ids[i]]
		if not a.online:
			continue
		for j in range(i + 1, ids.size()):
			var b: Radio = _radios[ids[j]]
			if not b.online:
				continue
			if _local(a.pos).distance_to(_local(b.pos)) > max_link_km * 1000.0:
				continue
			var ln := evaluate_link(a, b)
			if ln.rate_bps <= 0.0:
				continue
			_links["%s|%s" % [a.id, b.id]] = ln
			_add_edge(a.id, b.id, ln)
			_add_edge(b.id, a.id, ln)
		if a.dte_capable:
			var el := evaluate_earth_link(a)
			if el.rate_bps > 0.0:
				_earth_links[a.id] = el
	_compute_routes()
	network_updated.emit()


func _add_edge(from_id: StringName, to_id: StringName, ln: Link) -> void:
	if not _adj.has(from_id):
		_adj[from_id] = []
	_adj[from_id].append({"other": to_id, "link": ln})


## Widest path (maximum bottleneck rate, then lowest latency) from every node to Earth.
func _compute_routes() -> void:
	var best := {}
	var done := {}
	for id in _earth_links:
		var l: Link = _earth_links[id]
		best[id] = {"rate": l.rate_bps, "lat": l.latency_s, "snr": l.snr_db, "next": &"EARTH", "hops": 1}
	while true:
		var cur: StringName = &""
		var cur_rate := 0.0
		for id in best:
			if not done.has(id) and float(best[id]["rate"]) > cur_rate:
				cur = id
				cur_rate = float(best[id]["rate"])
		if cur == &"":
			break
		done[cur] = true
		for e in _adj.get(cur, []):
			var o: StringName = e["other"]
			if done.has(o):
				continue
			var l2: Link = e["link"]
			var rate := minf(cur_rate, l2.rate_bps)
			var lat: float = float(best[cur]["lat"]) + l2.latency_s
			var snr := minf(float(best[cur]["snr"]), l2.snr_db)
			var better := not best.has(o)
			if not better:
				var old_rate := float(best[o]["rate"])
				better = rate > old_rate * 1.001 or (absf(rate - old_rate) <= old_rate * 0.001 and lat < float(best[o]["lat"]))
			if better:
				best[o] = {"rate": rate, "lat": lat, "snr": snr, "next": cur, "hops": int(best[cur]["hops"]) + 1}
	_routes = best
	for id in _radios:
		var now := _routes.has(id)
		if _was_connected.get(id, false) != now:
			_was_connected[id] = now
			route_changed.emit(id, now)


# ================================================================== queries
func get_route(id: StringName) -> Dictionary:
	if not _routes.has(id):
		return {"connected": false, "rate_bps": 0.0, "latency_s": INF, "hops": 0, "path": [], "bars": 0}
	var path: Array = [id]
	var cur: StringName = id
	while cur != &"EARTH" and path.size() < 32:
		cur = _routes[cur]["next"]
		path.append(cur)
	var r: Dictionary = _routes[id]
	return {"connected": true, "rate_bps": r["rate"], "latency_s": r["lat"],
			"hops": r["hops"], "path": path, "bars": _bars(float(r["snr"]))}


func get_link(a_id: StringName, b_id: StringName) -> Link:
	var key := "%s|%s" % [a_id, b_id]
	if _links.has(key):
		return _links[key]
	key = "%s|%s" % [b_id, a_id]
	return _links.get(key, null)


func get_earth_link(id: StringName) -> Link:
	return _earth_links.get(id, null)


func earth_info(id: StringName) -> Dictionary:
	if not _radios.has(id):
		return {}
	var r: Radio = _radios[id]
	return earth_state(r.lat_deg, r.lon_deg)


## HUD lookup of the pre-baked coverage map at a world position (one transmitter set).
func baked_signal_dbm(world_pos: Vector3) -> float:
	if signal_map == null:
		return NAN
	var e := _local(world_pos)
	return signal_map.dbm_at(e.x, e.y)


func baked_bars(world_pos: Vector3) -> int:
	if signal_map == null:
		return 0
	var e := _local(world_pos)
	return signal_map.bars_at(e.x, e.y)


## Live received power from a radio at an arbitrary position (e.g. a walking player).
func live_signal_dbm(from_id: StringName, world_pos: Vector3, rx_gain_dbi: float = 3.0, mast_m: float = 2.0) -> float:
	if not _radios.has(from_id):
		return NAN
	var probe := Radio.new()
	probe.id = &"__probe"
	probe.pos = world_pos
	probe.mast_m = mast_m
	probe.gain_dbi = rx_gain_dbi
	var ln := evaluate_link(_radios[from_id], probe)
	return ln.rx_dbm
