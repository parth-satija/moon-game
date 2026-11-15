extends Node3D
## ORBITAL ASCENT, RENDEZVOUS AND DOCKING
##
## Fly the Starship off the lunar surface, get it into orbit and dock with a second Starship (the tanker).
## Nothing is scripted: the ship is a real 6-DOF rigid body in a real two-body orbit around the Moon.
##
##   * Position / velocity are kept in 64-bit floats (a Vector3 is only 32-bit and would wobble by ~0.1 m at
##     orbital distances). The 3D world is re-centred on the ship every frame (floating origin).
##   * Attitude: moments of inertia that change with propellant, Euler's equations (gyroscopic coupling),
##     Raptor thrust-vector control (gimbal with slew limit) and RCS thrusters that burn their own propellant.
##   * Engines: 3 Raptors, 40 % minimum throttle, ignition needs settled propellant (ullage burn), 8 starts total.
##   * Orbit: lunar gravity, orbital elements, closest-approach prediction, map view, time warp while coasting.
##   * Target: a tanker in a circular 100 km orbit whose plane does not contain the pad. It holds a local-vertical
##     attitude but slowly precesses and rolls, and its docking port moves with it.
##   * Docking: nose-to-nose. Closing speed, lateral speed, lateral offset, axis tilt, roll and rotation rates must all
##     be inside tolerance at the moment of contact, otherwise the ships are destroyed. Hulls collide too.
##   * Lighting: the Moon casts a real shadow. Parts of every orbit are night; use the floodlights.
##
## Controls: press F1 in the scene.  Esc = pause menu.  F5 = restart.

const MENU_SCENE := "res://scenes/main_menu.tscn"
const SHIP_MODEL := "res://assets/starship_mk1/scene.gltf"
const MOON_TEX := "res://moon_color_preview.png"
const SKY_SHADER := "res://scenes/star_sky.gdshader"
const MODEL_HEIGHT_UNITS := 215.45
const MODEL_BASE_Y := -79.52

# ---------------------------------------------------------------- physics constants
const R_MOON := 1737400.0
const MU := 4.9028e12
const G0 := 9.80665
const TARGET_ALT_M := 100000.0
const TARGET_R := R_MOON + TARGET_ALT_M
const LAUNCH_WAIT_S := 1500.0                 # the first launch window opens this long after the start

# Ship body frame: +Y nose, +X starboard, +Z belly (ventral). Origin = centre of gravity.
const SHIP_LEN := 50.0
const TAIL_Y := -20.0
const NOSE_Y := 30.0
const HULL_R := 4.6
const CAP_A := -14.0                          # collision capsule axis, tail end
const CAP_B := 24.0                           # collision capsule axis, nose end
const DOCK_PORT := Vector3(0.0, 30.0, 0.0)

const DRY_MASS := 85000.0
const PROP_MAX := 105000.0
const RCS_PROP_MAX := 1400.0
const ENGINE_N := 3
const ENGINE_THRUST := 1000000.0              # N per engine at 100 %
const ENGINE_MIN := 0.40
const ISP := 380.0
const RCS_ISP := 220.0
const GIMBAL_MAX := 0.105                     # rad, about 6 degrees
const GIMBAL_RATE := 0.17                     # rad/s
const GIMBAL_ARM := 20.0                      # engine plane to centre of gravity
const RCS_FORCE := 6000.0                     # N per translation axis
const RCS_TORQUE_PY := 600000.0               # N m, pitch / yaw
const RCS_TORQUE_ROLL := 150000.0             # N m
const RCS_ARM_PY := 22.0
const RCS_ARM_ROLL := 4.5
const IGNITIONS := 8
const ULLAGE_NEEDED_S := 1.5

# Docking tolerances (all must hold at the moment of contact)
const TOL_CLOSE_MAX := 0.25                   # m/s closing speed
const TOL_CLOSE_MIN := 0.01
const TOL_LAT_VEL := 0.12                     # m/s sideways speed
const TOL_LAT_OFF := 0.40                     # m sideways offset of the ports
const TOL_TILT_DEG := 4.0                     # axis misalignment
const TOL_ROLL_DEG := 6.0
const TOL_RATE_DEG := 0.35                    # deg/s relative rotation

const WARPS := [1, 2, 5, 10, 50, 100]
const NB_SIZE := 240.0

enum Mode { PAD, FLIGHT, DOCKED, FAILED }
enum Eng { OFF, STARTING, RUNNING }
enum Sas { OFF, DAMP, HOLD }

# ---------------------------------------------------------------- shaders (kept in code, no extra files)
const MOON_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

uniform sampler2D moon_tex : source_color, filter_linear_mipmap;

varying vec3 mdir;

float h31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vn3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(h31(i), h31(i + vec3(1.0, 0.0, 0.0)), f.x);
	float b = mix(h31(i + vec3(0.0, 1.0, 0.0)), h31(i + vec3(1.0, 1.0, 0.0)), f.x);
	float c = mix(h31(i + vec3(0.0, 0.0, 1.0)), h31(i + vec3(1.0, 0.0, 1.0)), f.x);
	float d = mix(h31(i + vec3(0.0, 1.0, 1.0)), h31(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

void vertex() {
	mdir = normalize(VERTEX);
}

void fragment() {
	vec3 d = normalize(mdir);
	float lon = atan(d.x, d.z);
	float lat = asin(clamp(d.y, -1.0, 1.0));
	vec2 uv = vec2(lon / 6.2831853 + 0.5, 0.5 - lat / 3.1415927);
	vec3 c = texture(moon_tex, uv).rgb;
	float n = vn3(d * 900.0) * 0.5 + vn3(d * 4200.0) * 0.3 + vn3(d * 21000.0) * 0.2;
	c *= 0.7 + 0.6 * n;
	ALBEDO = c;
	ROUGHNESS = 1.0;
}
"""

const CAP_SHADER := """
shader_type spatial;
render_mode diffuse_burley, specular_disabled, cull_disabled;

uniform sampler2D moon_tex : source_color, filter_linear_mipmap;
uniform vec3 center_local;
uniform vec3 e1;
uniform vec3 e2;

varying vec3 lp;

float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vn2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float oct(float fw, float s) {
	return 1.0 - smoothstep(0.15, 0.6, fw / s);
}

float craters(vec2 p, float s, float w) {
	if (w < 0.01) {
		return 0.0;
	}
	vec2 q = p / s;
	vec2 g = floor(q);
	vec2 f = fract(q);
	float h = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 o = vec2(float(i), float(j));
			vec2 cell = g + o;
			if (h21(cell + 17.0) > 0.5) {
				continue;
			}
			vec2 c = o + vec2(h21(cell + 7.3), h21(cell + 3.1)) - f;
			float rad = 0.18 + 0.28 * h21(cell + 11.7);
			float d = length(c) / rad;
			float bowl = d < 1.0 ? -(1.0 - d * d) : 0.0;
			float rim = exp(-pow((d - 1.0) * 5.0, 2.0)) * 0.3;
			h += (bowl * 0.45 + rim) * rad * s * 0.35 * w;
		}
	}
	return h;
}

float hf(vec2 p, float fw) {
	float h = 0.0;
	h += craters(p, 900.0, oct(fw, 900.0));
	h += craters(p, 260.0, oct(fw, 260.0));
	h += craters(p, 70.0, oct(fw, 70.0));
	h += craters(p, 18.0, oct(fw, 18.0));
	h += (vn2(p / 400.0) - 0.5) * 30.0 * oct(fw, 400.0);
	h += (vn2(p / 40.0) - 0.5) * 3.0 * oct(fw, 40.0);
	h += (vn2(p / 4.0) - 0.5) * 0.35 * oct(fw, 4.0);
	h += (vn2(p / 0.8) - 0.5) * 0.06 * oct(fw, 0.8);
	return h * smoothstep(55.0, 110.0, length(p));
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 rad = normalize(lp - center_local);
	vec2 p = vec2(dot(lp, e1), dot(lp, e2));
	float fw = max(length(fwidth(p)), 0.01);
	float eps = max(0.5, fw * 1.2);
	float h0 = hf(p, fw);
	float hx = hf(p + vec2(eps, 0.0), fw);
	float hy = hf(p + vec2(0.0, eps), fw);
	vec2 g = vec2(hx - h0, hy - h0) / eps;
	vec3 n = normalize(rad - g.x * e1 - g.y * e2);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float lon = atan(rad.x, rad.z);
	float lat = asin(clamp(rad.y, -1.0, 1.0));
	vec2 uv = vec2(lon / 6.2831853 + 0.5, 0.5 - lat / 3.1415927);
	vec3 col = texture(moon_tex, uv).rgb;
	float k = oct(fw, 0.5);
	float gr = vn2(p / 0.5) * 0.5 + vn2(p / 3.0) * 0.5;
	col *= 0.7 + 0.5 * gr * k + 0.25 * (1.0 - k);

	float r = length(p);
	float padmask = 1.0 - smoothstep(48.0, 52.0, r);
	vec3 padcol = vec3(0.40, 0.40, 0.42);
	float ring = 1.0 - smoothstep(0.0, 0.5 + fw, abs(r - 40.0));
	float ring2 = 1.0 - smoothstep(0.0, 0.4 + fw, abs(r - 12.0));
	float bar = (1.0 - smoothstep(0.0, 0.4 + fw, abs(p.x))) + (1.0 - smoothstep(0.0, 0.4 + fw, abs(p.y)));
	padcol = mix(padcol, vec3(0.85), clamp(ring + ring2 + bar * step(r, 40.0), 0.0, 1.0) * 0.8);
	col = mix(col, padcol, padmask);

	ALBEDO = col;
	ROUGHNESS = 1.0;
}
"""

const BALL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_back;

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec3 d = normalize(lp);
	float el = asin(clamp(d.y, -1.0, 1.0));
	vec3 sky = mix(vec3(0.10, 0.30, 0.62), vec3(0.32, 0.58, 0.88), 1.0 - smoothstep(0.0, 1.2, el));
	vec3 gnd = mix(vec3(0.33, 0.21, 0.09), vec3(0.52, 0.35, 0.17), 1.0 - smoothstep(0.0, 1.2, -el));
	vec3 col = d.y >= 0.0 ? sky : gnd;
	float w = fwidth(el) * 1.5;
	col = mix(col, vec3(1.0), 1.0 - smoothstep(0.0, 0.012 + w, abs(el)));
	float pl = abs(fract(el / 0.261799 + 0.5) - 0.5) * 0.261799;
	col = mix(col, vec3(1.0), (1.0 - smoothstep(0.0, 0.004 + w, pl)) * 0.30);
	float hd = atan(d.x, -d.z);
	float hl = abs(fract(hd / 0.261799 + 0.5) - 0.5) * 0.261799 * max(cos(el), 0.05);
	col = mix(col, vec3(1.0), (1.0 - smoothstep(0.0, 0.004 + fwidth(hd) * 0.8, hl)) * 0.22 * step(abs(el), 1.3));
	float rim = pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0);
	col *= 1.0 - 0.5 * rim;
	ALBEDO = col;
}
"""

const EARTH_SHADER := """
shader_type spatial;
render_mode unshaded;

uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
varying vec3 wn;

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float l = clamp(dot(normalize(wn), normalize(sun_dir)) * 1.3 + 0.08, 0.0, 1.0);
	float cl = 0.5 + 0.5 * sin(wn.x * 9.0 + sin(wn.y * 7.0) * 2.0) * sin(wn.z * 8.0 + wn.y * 5.0);
	vec3 base = mix(vec3(0.05, 0.18, 0.5), vec3(0.85, 0.88, 0.95), smoothstep(0.55, 0.9, cl));
	ALBEDO = base * l;
}
"""

# ---------------------------------------------------------------- scenario geometry
var _u := Vector3.UP                  # direction of the pad from the Moon's centre (also the inertial "up" at the pad)
var _h := Vector3.RIGHT               # launch heading (east)
var _n := Vector3.BACK                # normal of the plane through the pad that contains the heading
var _nt := Vector3.BACK               # normal of the target's orbital plane (tilted a little from _n)
var _e1 := Vector3.UP                 # in-plane basis of the target orbit
var _e2 := Vector3.RIGHT
var _sun := Vector3.RIGHT
var _earth := Vector3.UP
var _omega := 0.0                     # target mean motion
var _th0 := 0.0                       # target phase at t = 0
var _lambda := 0.0                    # best target lead angle at ignition for the standard ascent profile
var _tum_psi0 := 0.0
var _tum_tilt := 0.05
var _tum_prec := 0.007
var _tum_roll := 0.006

# ---------------------------------------------------------------- state
var _mode := Mode.PAD
var _t := 0.0                         # simulation clock
var _met := 0.0                       # mission elapsed time since lift-off
var _landed := true
var _docked := false

var _px := 0.0                        # ship position, Moon-centred inertial frame, doubles
var _py := 0.0
var _pz := 0.0
var _vx := 0.0
var _vy := 0.0
var _vz := 0.0
var _att := Basis.IDENTITY            # body -> inertial
var _w := Vector3.ZERO                # angular velocity, body frame, rad/s

var _tpx := 0.0                       # target position / velocity
var _tpy := 0.0
var _tpz := 0.0
var _tvx := 0.0
var _tvy := 0.0
var _tvz := 0.0
var _tb := Basis.IDENTITY
var _tport_vel := Vector3.ZERO
var _tw := Vector3.ZERO               # target angular velocity, inertial

var _prop := PROP_MAX
var _m_rcs := RCS_PROP_MAX
var _ignitions := IGNITIONS
var _eng := Eng.OFF
var _start_t := 0.0
var _n_eng := 3
var _throttle := 0.0
var _thrust_frac := 0.0
var _gim := Vector2.ZERO
var _ullage := 0.0
var _rcs_on := true
var _rcs_active := false
var _sas := Sas.OFF
var _sas_target := Basis.IDENTITY
var _lights_on := false

var _in_pitch := 0.0
var _in_yaw := 0.0
var _in_roll := 0.0
var _in_tr := Vector3.ZERO
var _c_pitch := 0.0
var _c_yaw := 0.0
var _c_roll := 0.0
var _f_main := Vector3.ZERO
var _tq_main := Vector3.ZERO
var _f_rcs := Vector3.ZERO
var _tq_rcs := Vector3.ZERO
var _accel := 0.0                     # last non-gravitational acceleration, m/s^2

var _warp_idx := 0
var _cam_mode := 0
var _chase_yaw := 0.8
var _chase_pitch := 0.18
var _chase_dist := 85.0
var _paused := false
var _map_open := false
var _help_open := true
var _ball_target_mode := false
var _frozen := false

# orbital elements of the ship (updated every physics frame)
var _el_valid := false
var _el_bound := false
var _el_a := 0.0
var _el_e := 0.0
var _el_rp := 0.0
var _el_ra := 0.0
var _el_T := 0.0
var _el_p := 0.0
var _el_ev := Vector3.RIGHT
var _el_hn := Vector3.ZERO
var _t_ap := -1.0
var _t_pe := -1.0
var _ca_dist := -1.0
var _ca_t := 0.0
var _ca_timer := 0.0
var _orbit_flag := false

# docking data
var _rel_cg := Vector3.ZERO
var _dk_a := 0.0
var _dk_lat := Vector3.ZERO
var _dk_range := 0.0
var _dk_closing := 0.0
var _dk_latv := Vector3.ZERO
var _dk_off_x := 0.0
var _dk_off_z := 0.0
var _dk_tilt_x := 0.0
var _dk_tilt_z := 0.0
var _dk_tilt := 0.0
var _dk_roll := 0.0
var _dk_rate := 0.0

var _log: Array = []
var _end_title := ""
var _end_text := ""

# ---------------------------------------------------------------- nodes
var _sun_light: DirectionalLight3D
var _earth_light: DirectionalLight3D
var _env: Environment
var _moon_mi: MeshInstance3D
var _cap_mi: MeshInstance3D
var _earth_mi: MeshInstance3D
var _ship_node: Node3D
var _flame_pivot: Node3D
var _flame: MeshInstance3D
var _engine_light: OmniLight3D
var _flood: SpotLight3D
var _tgt_node: Node3D
var _tgt_strobe: OmniLight3D
var _tgt_flood: SpotLight3D
var _cam_chase: Camera3D
var _cam_nose: Camera3D
var _cam_tgt: Camera3D
var _cam: Camera3D

var _layer: CanvasLayer
var _overlay: Control
var _left_lbl: Label
var _right_lbl: Label
var _help_lbl: Label
var _banner: Label
var _pause_root: Control
var _font: Font
var _nb_container: SubViewportContainer
var _ball: MeshInstance3D

## Set by F5 / "Restart flight" so that the pre-launch exchange is not repeated on every retry.
static var _skip_prelaunch := false


func _ready() -> void:
	randomize()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_setup_geometry()
	_init_state()
	_build_environment()
	_build_moon()
	_build_ship()
	_build_target()
	_build_cameras()
	_build_ui()
	_update_target(0.0)
	_update_elements()
	_sync_world()
	_msg("Pad clear. Wait for the launch window (use . to time-warp), then light the engines.", 0)
	_prelaunch_dialogue()


# ================================================================= setup

func _setup_geometry() -> void:
	var lon := 0.0
	var lat := 0.0
	if GameState.active:
		lon = float(LandingSite.lon_deg)
		lat = float(LandingSite.lat_deg)
	var lo := deg_to_rad(lon)
	var la := deg_to_rad(lat)
	_u = Vector3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo))
	var east := Vector3(cos(lo), 0.0, -sin(lo))
	_h = east
	_n = _u.cross(_h).normalized()
	var tilt := deg_to_rad(randf_range(0.4, 0.9) * (1.0 if randf() < 0.5 else -1.0))
	_nt = _n.rotated(_h, tilt).normalized()
	_e1 = (_u - _nt * _u.dot(_nt)).normalized()
	_e2 = _nt.cross(_e1).normalized()
	_sun = (_u * 0.45 + _h * 0.8 + _n * 0.35).normalized()
	_earth = (-_sun * 0.2 + _n * 0.7 + _u * 0.5).normalized()


func _init_state() -> void:
	_omega = sqrt(MU / (TARGET_R * TARGET_R * TARGET_R))
	var rp := R_MOON + 15000.0
	var semi := (rp + TARGET_R) * 0.5
	var t_half := PI * sqrt(semi * semi * semi / MU)
	_lambda = fposmod(PI + 0.065 - _omega * (190.0 + t_half), TAU)
	_th0 = fposmod(_lambda - _omega * LAUNCH_WAIT_S, TAU)
	_tum_psi0 = randf() * TAU
	_tum_tilt = deg_to_rad(randf_range(2.0, 3.5))
	_tum_prec = TAU / randf_range(700.0, 1100.0)
	_tum_roll = deg_to_rad(randf_range(0.25, 0.5)) * (1.0 if randf() < 0.5 else -1.0)

	var r0 := R_MOON - TAIL_Y
	_px = _u.x * r0
	_py = _u.y * r0
	_pz = _u.z * r0
	_vx = 0.0
	_vy = 0.0
	_vz = 0.0
	_att = Basis(_n, _u, _h)              # nose up, belly toward the launch direction
	_sas_target = _att
	_prop = PROP_MAX
	_m_rcs = RCS_PROP_MAX
	_ignitions = IGNITIONS


# ================================================================= scene building

func _build_environment() -> void:
	_sun_light = DirectionalLight3D.new()
	_sun_light.light_energy = 1.5
	_sun_light.shadow_enabled = true
	_sun_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun_light.directional_shadow_max_distance = 600.0
	add_child(_sun_light)
	var hint := Vector3.UP if absf(_sun.y) < 0.95 else Vector3.RIGHT
	_sun_light.transform = Transform3D(Basis.looking_at(-_sun, hint), Vector3.ZERO)

	_earth_light = DirectionalLight3D.new()
	_earth_light.light_energy = 0.05
	_earth_light.light_color = Color(0.6, 0.72, 1.0)
	add_child(_earth_light)
	var hint2 := Vector3.UP if absf(_earth.y) < 0.95 else Vector3.RIGHT
	_earth_light.transform = Transform3D(Basis.looking_at(-_earth, hint2), Vector3.ZERO)

	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load(SKY_SHADER) as Shader
	sky_mat.set_shader_parameter("sun_dir", _sun)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	_env = Environment.new()
	_env.background_mode = Environment.BG_SKY
	_env.sky = sky
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.03, 0.03, 0.035)
	_env.ambient_light_energy = 1.0
	_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_env.glow_enabled = true
	_env.glow_intensity = 0.5
	_env.glow_hdr_threshold = 1.0
	var we := WorldEnvironment.new()
	we.environment = _env
	add_child(we)

	# Earth: a lit disc at a fixed direction (re-centred on the ship every frame, like a sky object).
	var em := SphereMesh.new()
	em.radius = 150000.0
	em.height = 300000.0
	em.radial_segments = 48
	em.rings = 24
	var esh := Shader.new()
	esh.code = EARTH_SHADER
	var emat := ShaderMaterial.new()
	emat.shader = esh
	emat.set_shader_parameter("sun_dir", _sun)
	_earth_mi = MeshInstance3D.new()
	_earth_mi.mesh = em
	_earth_mi.material_override = emat
	_earth_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_earth_mi)


func _build_moon() -> void:
	var tex := load(MOON_TEX) as Texture2D
	if tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
		img.fill(Color(0.55, 0.55, 0.55))
		tex = ImageTexture.create_from_image(img)

	var sh := Shader.new()
	sh.code = MOON_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("moon_tex", tex)
	var sm := SphereMesh.new()
	sm.radius = R_MOON - 70.0
	sm.height = 2.0 * (R_MOON - 70.0)
	sm.radial_segments = 320
	sm.rings = 160
	_moon_mi = MeshInstance3D.new()
	_moon_mi.mesh = sm
	_moon_mi.material_override = mat
	_moon_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_moon_mi)

	# Near-field terrain cap around the pad: a patch of the true sphere, vertices stored relative to the pad point.
	var csh := Shader.new()
	csh.code = CAP_SHADER
	var cmat := ShaderMaterial.new()
	cmat.shader = csh
	cmat.set_shader_parameter("moon_tex", tex)
	cmat.set_shader_parameter("center_local", -_u * R_MOON)
	cmat.set_shader_parameter("e1", _h)
	cmat.set_shader_parameter("e2", _n)
	_cap_mi = MeshInstance3D.new()
	_cap_mi.mesh = _make_cap_mesh()
	_cap_mi.material_override = cmat
	_cap_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_cap_mi)


func _make_cap_mesh() -> ArrayMesh:
	var rings := 120
	var segs := 96
	var alpha_max := 0.03
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in range(rings + 1):
		var f := float(i) / float(rings)
		var alpha := alpha_max * f * f
		var ca := cos(alpha)
		var sa := sin(alpha)
		for j in range(segs + 1):
			var phi := TAU * float(j) / float(segs)
			var tang := _h * cos(phi) + _n * sin(phi)
			var dir := _u * ca + tang * sa
			verts.append(dir * R_MOON - _u * R_MOON)
			norms.append(dir)
	var stride := segs + 1
	for i in range(rings):
		for j in range(segs):
			var a := i * stride + j
			var b := a + 1
			var c := a + stride
			var d := c + 1
			idx.append(a)
			idx.append(c)
			idx.append(b)
			idx.append(b)
			idx.append(c)
			idx.append(d)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


func _make_ship_model(parent: Node3D) -> void:
	var sc := SHIP_LEN / MODEL_HEIGHT_UNITS
	var holder := Node3D.new()
	parent.add_child(holder)
	var packed := load(SHIP_MODEL) as PackedScene
	if packed:
		holder.scale = Vector3.ONE * sc
		holder.position = Vector3(0.0, TAIL_Y - MODEL_BASE_Y * sc, 0.0)
		holder.add_child(packed.instantiate())
	else:
		push_warning("OrbitalDocking: could not load %s, using a placeholder hull." % SHIP_MODEL)
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = HULL_R * 0.5
		cyl.bottom_radius = HULL_R
		cyl.height = SHIP_LEN
		mi.mesh = cyl
		mi.position = Vector3(0.0, (TAIL_Y + NOSE_Y) * 0.5, 0.0)
		holder.add_child(mi)


func _glow_material(col: Color, energy: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


func _port_ring(parent: Node3D, col: Color) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 1.9
	tm.outer_radius = 2.3
	tm.rings = 32
	tm.ring_segments = 12
	ring.mesh = tm
	ring.material_override = _glow_material(col, 2.0)
	ring.position = Vector3(0.0, NOSE_Y, 0.0)
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(ring)


func _build_ship() -> void:
	_ship_node = Node3D.new()
	_ship_node.name = "Ship"
	add_child(_ship_node)
	_make_ship_model(_ship_node)
	_port_ring(_ship_node, Color(0.3, 1.0, 0.5))

	# Raptor plume: narrow at the nozzle, spreading downstream, with the light it throws.
	_flame_pivot = Node3D.new()
	_flame_pivot.position = Vector3(0.0, TAIL_Y, 0.0)
	_ship_node.add_child(_flame_pivot)
	_flame = MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 2.4
	cone.bottom_radius = 7.0
	cone.height = 38.0
	cone.radial_segments = 20
	cone.rings = 1
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fm.cull_mode = BaseMaterial3D.CULL_DISABLED
	fm.albedo_color = Color(0.7, 0.8, 1.0, 0.35)
	fm.emission_enabled = true
	fm.emission = Color(0.55, 0.65, 1.0)
	fm.emission_energy_multiplier = 2.0
	cone.material = fm
	_flame.mesh = cone
	_flame.position = Vector3(0.0, -19.0, 0.0)
	_flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flame_pivot.add_child(_flame)
	_flame_pivot.visible = false

	_engine_light = OmniLight3D.new()
	_engine_light.light_color = Color(0.75, 0.8, 1.0)
	_engine_light.light_energy = 0.0
	_engine_light.omni_range = 120.0
	_engine_light.position = Vector3(0.0, TAIL_Y - 6.0, 0.0)
	_ship_node.add_child(_engine_light)

	_flood = SpotLight3D.new()
	_flood.light_energy = 12.0
	_flood.spot_range = 160.0
	_flood.spot_angle = 28.0
	_flood.spot_attenuation = 0.6
	_flood.transform = Transform3D(Basis.looking_at(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0)), Vector3(0.0, NOSE_Y - 1.0, 0.0))
	_flood.visible = false
	_ship_node.add_child(_flood)


func _build_target() -> void:
	_tgt_node = Node3D.new()
	_tgt_node.name = "Tanker"
	add_child(_tgt_node)
	_make_ship_model(_tgt_node)
	_port_ring(_tgt_node, Color(1.0, 0.55, 0.2))

	# Docking target cross: four lamps around the port.
	for i in range(4):
		var a := float(i) * PI * 0.5
		var lamp := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.22
		sm.height = 0.44
		lamp.mesh = sm
		lamp.material_override = _glow_material(Color(1.0, 0.95, 0.8) if i != 0 else Color(1.0, 0.2, 0.2), 4.0)
		lamp.position = Vector3(cos(a) * 3.2, NOSE_Y - 0.6, sin(a) * 3.2)
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_tgt_node.add_child(lamp)

	_tgt_strobe = OmniLight3D.new()
	_tgt_strobe.light_color = Color(1.0, 0.3, 0.3)
	_tgt_strobe.light_energy = 0.0
	_tgt_strobe.omni_range = 40.0
	_tgt_strobe.position = Vector3(0.0, TAIL_Y + 6.0, 5.0)
	_tgt_node.add_child(_tgt_strobe)

	_tgt_flood = SpotLight3D.new()
	_tgt_flood.light_energy = 10.0
	_tgt_flood.spot_range = 160.0
	_tgt_flood.spot_angle = 35.0
	_tgt_flood.spot_attenuation = 0.5
	_tgt_flood.transform = Transform3D(Basis.looking_at(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0)), Vector3(0.0, NOSE_Y - 1.0, 0.0))
	_tgt_node.add_child(_tgt_flood)


func _build_cameras() -> void:
	_cam_chase = Camera3D.new()
	_cam_chase.near = 10
	_cam_chase.far = 2.0e7
	_cam_chase.fov = 60.0
	_ship_node.add_child(_cam_chase)

	_cam_nose = Camera3D.new()
	_cam_nose.near = 10
	_cam_nose.far = 2.0e7
	_cam_nose.fov = 55.0
	_cam_nose.transform = Transform3D(Basis.looking_at(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0)), Vector3(0.0, NOSE_Y + 0.5, 0.0))
	_ship_node.add_child(_cam_nose)

	_cam_tgt = Camera3D.new()
	_cam_tgt.near = 10
	_cam_tgt.far = 2.0e7
	_cam_tgt.fov = 30.0
	add_child(_cam_tgt)

	_cam = _cam_chase
	_cam.current = true
	_update_chase_cam()


func _update_chase_cam() -> void:
	var center := Vector3(0.0, 5.0, 0.0)
	var off := Vector3(sin(_chase_yaw) * cos(_chase_pitch), sin(_chase_pitch), cos(_chase_yaw) * cos(_chase_pitch)) * _chase_dist
	var pos := center + off
	_cam_chase.transform = Transform3D(Basis.looking_at(center - pos, Vector3(0.0, 1.0, 0.0)), pos)


func _set_camera(mode: int) -> void:
	_cam_mode = posmod(mode, 3)
	match _cam_mode:
		0:
			_cam = _cam_chase
		1:
			_cam = _cam_nose
		_:
			_cam = _cam_tgt
	_cam.current = true


# ================================================================= UI

func _panel_label(anchor_right: bool) -> Label:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.02, 0.05, 0.55)
	sb.border_color = Color(0.4, 0.55, 0.7, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8.0)
	pc.add_theme_stylebox_override("panel", sb)
	pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if anchor_right:
		pc.anchor_left = 1.0
		pc.anchor_right = 1.0
		pc.offset_right = -12.0
		pc.offset_top = 12.0
		pc.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	else:
		pc.offset_left = 12.0
		pc.offset_top = 12.0
	_layer.add_child(pc)
	var l := Label.new()
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pc.add_child(l)
	return l


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 5
	add_child(_layer)

	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Cascadia Mono", "Courier New", "monospace"])
	_font = mono

	# --- navball (rendered in its own 3D world)
	_nb_container = SubViewportContainer.new()
	_nb_container.stretch = true
	_nb_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_nb_container.anchor_left = 0.5
	_nb_container.anchor_right = 0.5
	_nb_container.anchor_top = 1.0
	_nb_container.anchor_bottom = 1.0
	_nb_container.offset_left = -NB_SIZE * 0.5
	_nb_container.offset_right = NB_SIZE * 0.5
	_nb_container.offset_top = -NB_SIZE - 8.0
	_nb_container.offset_bottom = -8.0
	_layer.add_child(_nb_container)
	var vp := SubViewport.new()
	vp.size = Vector2i(int(NB_SIZE), int(NB_SIZE))
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_nb_container.add_child(vp)
	var bcam := Camera3D.new()
	bcam.projection = Camera3D.PROJECTION_ORTHOGONAL
	bcam.size = 2.1
	bcam.near = 0.1
	bcam.far = 20.0
	bcam.position = Vector3(0.0, 0.0, 5.0)
	vp.add_child(bcam)
	var bsh := Shader.new()
	bsh.code = BALL_SHADER
	var bmat := ShaderMaterial.new()
	bmat.shader = bsh
	var bm := SphereMesh.new()
	bm.radius = 1.0
	bm.height = 2.0
	bm.radial_segments = 96
	bm.rings = 48
	_ball = MeshInstance3D.new()
	_ball.mesh = bm
	_ball.material_override = bmat
	vp.add_child(_ball)

	# --- drawing overlay (markers, gauges, docking scope, map)
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_overlay)
	_overlay.draw.connect(_on_overlay_draw)

	_left_lbl = _panel_label(false)
	_right_lbl = _panel_label(true)

	_help_lbl = Label.new()
	_help_lbl.add_theme_font_override("font", _font)
	_help_lbl.add_theme_font_size_override("font_size", 15)
	_help_lbl.add_theme_color_override("font_color", Color(0.9, 0.97, 1.0))
	_help_lbl.set_anchors_preset(Control.PRESET_CENTER)
	_help_lbl.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_help_lbl.grow_vertical = Control.GROW_DIRECTION_BOTH
	_help_lbl.text = _help_text()
	var hp := PanelContainer.new()
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.0, 0.02, 0.05, 0.9)
	hsb.border_color = Color(0.4, 0.6, 0.8, 0.8)
	hsb.set_border_width_all(2)
	hsb.set_corner_radius_all(8)
	hsb.set_content_margin_all(18.0)
	hp.add_theme_stylebox_override("panel", hsb)
	hp.set_anchors_preset(Control.PRESET_CENTER)
	hp.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hp.grow_vertical = Control.GROW_DIRECTION_BOTH
	hp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp.name = "HelpPanel"
	_layer.add_child(hp)
	_help_lbl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hp.add_child(_help_lbl)

	_banner = Label.new()
	_banner.add_theme_font_override("font", _font)
	_banner.add_theme_font_size_override("font_size", 22)
	_banner.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	_layer.add_child(_banner)

	_build_pause_menu()


func _build_pause_menu() -> void:
	_pause_root = Control.new()
	_pause_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_pause_root.visible = false
	_layer.add_child(_pause_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pause_root.add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(1.0, 0.75, 0.35))
	box.add_child(title)
	_pause_button(box, "Resume", _toggle_pause)
	_pause_button(box, "Restart flight (F5)", _restart)
	_pause_button(box, "Main menu", _to_menu)


func _pause_button(parent: Control, text: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(handler)
	parent.add_child(b)


func _help_text() -> String:
	return "\n".join(PackedStringArray([
		"ORBITAL DOCKING  -  FLIGHT MANUAL                                  (F1 to close)",
		"",
		"ATTITUDE       W / S  pitch down / up        A / D  yaw left / right        Q / E  roll left / right",
		"RCS TRANSLATE  I / K  forward / back         J / L  left / right            H / N  up / down",
		"MAIN ENGINES   SPACE  start / stop (needs settled propellant: hold I for 1.5 s first)",
		"               1 / 3  one or three Raptors   SHIFT / CTRL  throttle up / down   Z  full   X  cut + shut down",
		"               Engines cannot throttle below 40 %. Pitch and yaw steer by gimbaling the engines while they burn.",
		"SAS            T  on / off     Y  rate-damp / attitude-hold     R  RCS on / off  (RCS propellant is limited)",
		"TIME WARP      ,  slower   .  faster   BACKSPACE  1x      (coasting only, limited near the target)",
		"CAMERA         C  chase / nose docking cam / target cam      mouse wheel zoom, right-drag orbits chase cam",
		"DISPLAYS       M  orbit map     G  navball markers: orbit / target     F  floodlights",
		"GAME           F5  restart      ESC  pause / menu",
		"",
		"MISSION",
		"  1. Wait for the launch window (right panel). Light the engines, lift off, pitch over to the east (090 on the navball).",
		"  2. Burn until the apoapsis reaches about 100 km with the periapsis near the surface, cut, coast to the apoapsis.",
		"  3. Circularise at 100 km and match the tanker's orbital plane (its plane is tilted slightly: watch the relative inclination).",
		"  4. Close to under 1 km, kill the relative velocity, then fly a straight, slow nose-to-nose approach to the tanker's docking port.",
		"  5. At contact you need: closing 0.01-0.25 m/s, sideways speed < 0.12 m/s, offset < 0.4 m, axis error < 4 deg,",
		"     roll error < 6 deg, relative rotation < 0.35 deg/s. Anything else destroys both ships.",
		"",
		"The tanker keeps a local-vertical attitude but slowly precesses and rolls: its port moves, and you must match it.",
		"Navball: heading 090 is the direction of orbital travel, 000 is the tanker's orbit normal. Centre = where the nose points.",
		"Prop and RCS are finite. Docking in darkness is normal: use the floodlights (F).",
	]))


# ================================================================= input

func _k(code: Key) -> bool:
	return Input.is_physical_key_pressed(code)


func _read_input(delta: float) -> void:
	_in_pitch = (1.0 if _k(KEY_S) else 0.0) - (1.0 if _k(KEY_W) else 0.0)
	_in_yaw = (1.0 if _k(KEY_D) else 0.0) - (1.0 if _k(KEY_A) else 0.0)
	_in_roll = (1.0 if _k(KEY_E) else 0.0) - (1.0 if _k(KEY_Q) else 0.0)
	_in_tr = Vector3(
		(1.0 if _k(KEY_L) else 0.0) - (1.0 if _k(KEY_J) else 0.0),
		(1.0 if _k(KEY_I) else 0.0) - (1.0 if _k(KEY_K) else 0.0),
		(1.0 if _k(KEY_N) else 0.0) - (1.0 if _k(KEY_H) else 0.0))
	var dthr := (1.0 if _k(KEY_SHIFT) else 0.0) - (1.0 if _k(KEY_CTRL) else 0.0)
	_throttle = clampf(_throttle + dthr * 0.5 * delta, 0.0, 1.0)
	if _frozen or _docked:
		_in_pitch = 0.0
		_in_yaw = 0.0
		_in_roll = 0.0
		_in_tr = Vector3.ZERO


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_chase_dist = clampf(_chase_dist * 0.92, 25.0, 400.0)
			_update_chase_cam()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_chase_dist = clampf(_chase_dist * 1.08, 25.0, 400.0)
			_update_chase_cam()
		return
	if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
		_chase_yaw -= event.relative.x * 0.006
		_chase_pitch = clampf(_chase_pitch + event.relative.y * 0.006, -1.4, 1.4)
		_update_chase_cam()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_ESCAPE:
			_toggle_pause()
		KEY_F1:
			_help_open = not _help_open
		KEY_F5:
			_restart()
		KEY_SPACE:
			_toggle_engines()
		KEY_1:
			_n_eng = 1
			_msg("Single-engine mode", 0)
		KEY_3:
			_n_eng = 3
			_msg("Three-engine mode", 0)
		KEY_Z:
			_throttle = 1.0
		KEY_X:
			_throttle = 0.0
			if _eng != Eng.OFF:
				_shutdown_engines()
		KEY_T:
			_sas = Sas.OFF if _sas != Sas.OFF else Sas.DAMP
			_sas_target = _att
			_msg("SAS " + ["OFF", "RATE DAMP", "ATTITUDE HOLD"][_sas], 0)
		KEY_Y:
			if _sas == Sas.DAMP:
				_sas = Sas.HOLD
				_sas_target = _att
			elif _sas == Sas.HOLD:
				_sas = Sas.DAMP
			_msg("SAS " + ["OFF", "RATE DAMP", "ATTITUDE HOLD"][_sas], 0)
		KEY_R:
			_rcs_on = not _rcs_on
			_msg("RCS " + ("ON" if _rcs_on else "OFF"), 0)
		KEY_COMMA:
			_warp_idx = maxi(0, _warp_idx - 1)
		KEY_PERIOD:
			_warp_idx = mini(WARPS.size() - 1, _warp_idx + 1)
		KEY_BACKSPACE:
			_warp_idx = 0
		KEY_C:
			_set_camera(_cam_mode + 1)
		KEY_M:
			_map_open = not _map_open
		KEY_G:
			_ball_target_mode = not _ball_target_mode
		KEY_F:
			_lights_on = not _lights_on
			_flood.visible = _lights_on


func _toggle_pause() -> void:
	_paused = not _paused
	_pause_root.visible = _paused


# The exchange on the pad before liftoff. Mission control only gives the navigation: heading, window and target orbit
# (the same numbers as the flight manual, F1).
func _prelaunch_dialogue() -> void:
	var skip := _skip_prelaunch
	_skip_prelaunch = false
	if skip:
		return
	Dialogue.say("Pre-launch checks complete.", 0.0, "Suit computer")
	Dialogue.say("We have your signal, Eagle. You're cleared for departure. Launch heading is 090, due east: pitch over onto it once you're clear of the pad.", 0.0, "Mission Control")
	Dialogue.say("Your window opens in about %d minutes, so time-warp to it. Burn for a %d km apoapsis, then circularise: Tanker-1 is waiting in that orbit." % [int(round(LAUNCH_WAIT_S / 60.0)), int(round(TARGET_ALT_M / 1000.0))], 0.0, "Mission Control")
	Dialogue.say("Beginning launch sequence.", 0.0, "Astronaut")


func _restart() -> void:
	_skip_prelaunch = true
	get_tree().reload_current_scene()


func _to_menu() -> void:
	get_tree().change_scene_to_file(MENU_SCENE)


func _toggle_engines() -> void:
	if _frozen or _docked:
		return
	if _eng != Eng.OFF:
		_shutdown_engines()
		return
	if _ignitions <= 0:
		_msg("NO IGNITIONS LEFT", 3)
		return
	if _prop <= 0.0:
		_msg("NO PROPELLANT", 3)
		return
	if not _landed and _ullage < ULLAGE_NEEDED_S:
		_msg("IGNITION ABORTED: propellant not settled. Fire forward RCS (I) for %.1f s first." % ULLAGE_NEEDED_S, 2)
		return
	_ignitions -= 1
	_eng = Eng.STARTING
	_start_t = 0.0
	_msg("ENGINE START SEQUENCE   (%d starts left)" % _ignitions, 1)


func _shutdown_engines() -> void:
	_eng = Eng.OFF
	_msg("ENGINES SHUT DOWN", 0)


# ================================================================= main loop

func _physics_process(delta: float) -> void:
	if _paused:
		return
	_read_input(delta)
	if _frozen:
		_sync_world()
		return
	var warp := _effective_warp()
	var total := delta * float(warp)
	var n := maxi(1, ceili(total / 0.05))
	var dt := total / float(n)
	for i in range(n):
		_sim_step(dt)
		if _frozen:
			break
	_update_elements()
	_ca_timer -= delta
	if _ca_timer <= 0.0:
		_ca_timer = 1.0
		_predict_closest()
	_check_milestones()
	_sync_world()


func _process(_delta: float) -> void:
	_update_panels()
	if _overlay:
		_overlay.queue_redraw()


func _effective_warp() -> int:
	var w: int = WARPS[_warp_idx]
	if w <= 1:
		return 1
	if _frozen:
		return 1
	if _eng != Eng.OFF or _thrust_frac > 0.001:
		return 1
	if _in_tr.length() > 0.01 or absf(_in_pitch) + absf(_in_yaw) + absf(_in_roll) > 0.01:
		return 1
	if not _landed and not _docked:
		var rg := _rel_range()
		if rg < 2000.0:
			return 1
		if rg < 20000.0:
			w = mini(w, 5)
		var r := sqrt(_px * _px + _py * _py + _pz * _pz)
		var vr := (_px * _vx + _py * _vy + _pz * _vz) / r
		if r - R_MOON < 3000.0 and vr < -1.0:
			return 1
	return w


func _rel_range() -> float:
	var dx := _tpx - _px
	var dy := _tpy - _py
	var dz := _tpz - _pz
	return sqrt(dx * dx + dy * dy + dz * dz)


func _mass() -> float:
	return DRY_MASS + _prop + _m_rcs


func _inertia() -> Vector3:
	var m := _mass()
	return Vector3(m * 238.0, m * 12.5, m * 238.0)


# ================================================================= one physics step

func _sim_step(dt: float) -> void:
	_t += dt
	_update_target(_t)
	if _docked:
		_follow_dock()
		return

	_compute_commands()
	_update_engine(dt)
	_update_rcs(dt)

	var mass := _mass()
	var f_body := _f_main + _f_rcs
	var a_ng := (_att * f_body) / mass
	_accel = f_body.length() / mass

	if _landed:
		var r := sqrt(_px * _px + _py * _py + _pz * _pz)
		var g := MU / (r * r)
		var up_thrust := (_att * _f_main).dot(Vector3(_px, _py, _pz) / r) / mass
		if up_thrust > g * 1.02:
			_landed = false
			if _mode == Mode.PAD:
				_mode = Mode.FLIGHT
			_msg("LIFTOFF", 1)
		else:
			_vx = 0.0
			_vy = 0.0
			_vz = 0.0
			_w = Vector3.ZERO
			return

	_met += dt

	# attitude (Euler's equations in the body frame)
	var inertia := _inertia()
	var iw := Vector3(inertia.x * _w.x, inertia.y * _w.y, inertia.z * _w.z)
	var tau := _tq_main + _tq_rcs - _w.cross(iw)
	_w += Vector3(tau.x / inertia.x, tau.y / inertia.y, tau.z / inertia.z) * dt
	var ang := _w.length() * dt
	if ang > 1e-9:
		_att = (_att * Basis(_w.normalized(), ang)).orthonormalized()

	# translation: velocity Verlet in doubles
	var r2 := _px * _px + _py * _py + _pz * _pz
	var k := -MU / (r2 * sqrt(r2))
	_vx += (_px * k + a_ng.x) * 0.5 * dt
	_vy += (_py * k + a_ng.y) * 0.5 * dt
	_vz += (_pz * k + a_ng.z) * 0.5 * dt
	_px += _vx * dt
	_py += _vy * dt
	_pz += _vz * dt
	r2 = _px * _px + _py * _py + _pz * _pz
	k = -MU / (r2 * sqrt(r2))
	_vx += (_px * k + a_ng.x) * 0.5 * dt
	_vy += (_py * k + a_ng.y) * 0.5 * dt
	_vz += (_pz * k + a_ng.z) * 0.5 * dt

	var settling := (_in_tr.y > 0.5 and _rcs_on and _m_rcs > 0.0) or _thrust_frac > 0.05
	if settling:
		_ullage += dt
	else:
		_ullage = maxf(0.0, _ullage - dt * 0.25)

	_check_moon_contact()
	if _frozen:
		return
	var rel := Vector3(_tpx - _px, _tpy - _py, _tpz - _pz)
	if rel.length() < 160.0:
		_compute_dock_data()
		_check_docking_and_hulls(rel)


func _compute_commands() -> void:
	var sp := 0.0
	var sy := 0.0
	var sr := 0.0
	var manual_any := absf(_in_pitch) + absf(_in_yaw) + absf(_in_roll) > 0.01
	if _sas != Sas.OFF and (_rcs_on and _m_rcs > 0.0 or _thrust_frac > 0.05):
		var w_des := Vector3.ZERO
		if _sas == Sas.HOLD:
			if manual_any:
				_sas_target = _att
			else:
				var q := (_att.inverse() * _sas_target).get_rotation_quaternion()
				if q.w < 0.0:
					q = Quaternion(-q.x, -q.y, -q.z, -q.w)
				w_des = (q.get_axis() * q.get_angle() * 0.35).limit_length(0.05)
		var err := w_des - _w
		if absf(_in_pitch) < 0.01:
			sp = -_sas_axis(err.x)
		if absf(_in_yaw) < 0.01:
			sy = -_sas_axis(err.z)
		if absf(_in_roll) < 0.01:
			sr = -_sas_axis(err.y)
	_c_pitch = clampf(_in_pitch + sp, -1.0, 1.0)
	_c_yaw = clampf(_in_yaw + sy, -1.0, 1.0)
	_c_roll = clampf(_in_roll + sr, -1.0, 1.0)


func _sas_axis(err: float) -> float:
	if absf(err) < 0.0004:
		return 0.0
	return clampf(err / 0.01, -1.0, 1.0)


func _update_engine(dt: float) -> void:
	_f_main = Vector3.ZERO
	_tq_main = Vector3.ZERO
	if _eng == Eng.STARTING:
		_start_t += dt
		if _start_t >= 1.6:
			_eng = Eng.RUNNING
			_msg("ENGINES NOMINAL", 1)
	if _prop <= 0.0 and _eng != Eng.OFF:
		_eng = Eng.OFF
		_msg("FLAMEOUT: OUT OF PROPELLANT", 3)
	var target := 0.0
	if _eng == Eng.RUNNING:
		target = ENGINE_MIN + (1.0 - ENGINE_MIN) * _throttle
	var rate := 1.2 if target > _thrust_frac else 5.0
	_thrust_frac = move_toward(_thrust_frac, target, rate * dt)

	var gcmd := Vector2(-_c_yaw * GIMBAL_MAX, _c_pitch * GIMBAL_MAX)
	_gim = _gim.move_toward(gcmd, GIMBAL_RATE * dt)

	var f := _thrust_frac * ENGINE_THRUST * float(_n_eng)
	if f > 0.0:
		var d := Vector3(_gim.x, 1.0, _gim.y).normalized()
		_f_main = d * f
		_tq_main = Vector3(0.0, -GIMBAL_ARM, 0.0).cross(_f_main)
		_prop = maxf(0.0, _prop - f / (ISP * G0) * dt)


func _update_rcs(dt: float) -> void:
	_f_rcs = Vector3.ZERO
	_tq_rcs = Vector3.ZERO
	_rcs_active = false
	if not _rcs_on or _m_rcs <= 0.0:
		return
	_f_rcs = _in_tr * RCS_FORCE
	var tqx := 0.0
	var tqz := 0.0
	if _thrust_frac < 0.05:
		tqx = -_c_pitch * RCS_TORQUE_PY
		tqz = -_c_yaw * RCS_TORQUE_PY
	var tqy := -_c_roll * RCS_TORQUE_ROLL
	_tq_rcs = Vector3(tqx, tqy, tqz)
	var force_sum := absf(_f_rcs.x) + absf(_f_rcs.y) + absf(_f_rcs.z)
	force_sum += (absf(tqx) + absf(tqz)) / RCS_ARM_PY + absf(tqy) / RCS_ARM_ROLL
	if force_sum > 0.0:
		_rcs_active = true
		_m_rcs = maxf(0.0, _m_rcs - force_sum / (RCS_ISP * G0) * dt)
		if _m_rcs <= 0.0:
			_msg("RCS PROPELLANT EXHAUSTED", 3)


# ================================================================= target

func _target_basis(t: float) -> Basis:
	var th := _th0 + _omega * t
	var pos_dir := _e1 * cos(th) + _e2 * sin(th)
	var vel_dir := -_e1 * sin(th) + _e2 * cos(th)
	var yb := -vel_dir                    # nose points backwards along the orbit
	var zb := -pos_dir                    # belly toward the Moon
	var xb := yb.cross(zb)
	var base := Basis(xb, yb, zb)
	var psi := _tum_psi0 + _tum_prec * t
	var tilt := Basis(Vector3(cos(psi), 0.0, sin(psi)), _tum_tilt)
	var roll := Basis(Vector3(0.0, 1.0, 0.0), _tum_roll * t)
	return base * tilt * roll


func _update_target(t: float) -> void:
	var th := _th0 + _omega * t
	var c := cos(th)
	var s := sin(th)
	_tpx = TARGET_R * (c * _e1.x + s * _e2.x)
	_tpy = TARGET_R * (c * _e1.y + s * _e2.y)
	_tpz = TARGET_R * (c * _e1.z + s * _e2.z)
	var vt := TARGET_R * _omega
	_tvx = vt * (-s * _e1.x + c * _e2.x)
	_tvy = vt * (-s * _e1.y + c * _e2.y)
	_tvz = vt * (-s * _e1.z + c * _e2.z)
	_tb = _target_basis(t)
	var tb2 := _target_basis(t + 0.1)
	_tport_vel = (tb2 * DOCK_PORT - _tb * DOCK_PORT) / 0.1
	var dq := (tb2 * _tb.inverse()).get_rotation_quaternion()
	_tw = dq.get_axis() * dq.get_angle() / 0.1


# ================================================================= contacts

func _check_moon_contact() -> void:
	var r := sqrt(_px * _px + _py * _py + _pz * _pz)
	var up := Vector3(_px, _py, _pz) / r
	var alt_c := r - R_MOON
	var axis := _att.y
	var ad := axis.dot(up)
	var sinv := sqrt(maxf(0.0, 1.0 - ad * ad))
	var h_tail := alt_c + TAIL_Y * ad
	var h_nose := alt_c + NOSE_Y * ad
	var clearance := minf(minf(h_tail, h_nose), alt_c - HULL_R * sinv)
	var vv := Vector3(_vx, _vy, _vz)
	var vr := vv.dot(up)
	if clearance > 0.0 or vr >= 0.0:
		return
	var vh := sqrt(maxf(0.0, vv.length_squared() - vr * vr))
	if absf(vr) < 3.0 and vh < 3.0 and ad > 0.93 and _w.length() < 0.05:
		_landed = true
		_vx = 0.0
		_vy = 0.0
		_vz = 0.0
		_w = Vector3.ZERO
		_msg("TOUCHDOWN", 1)
		if _eng != Eng.OFF:
			_shutdown_engines()
		_thrust_frac = 0.0
	else:
		_fail("CRASHED INTO THE MOON", "Impact at %.1f m/s vertical, %.1f m/s horizontal, tilt %.0f deg from vertical." % [absf(vr), vh, rad_to_deg(acos(clampf(ad, -1.0, 1.0)))])


func _check_docking_and_hulls(rel: Vector3) -> void:
	if _dk_a <= 0.1 and _dk_a > -8.0 and _dk_lat.length() < 3.5:
		_attempt_dock()
		return
	var s0 := _att * Vector3(0.0, CAP_A, 0.0)
	var s1 := _att * Vector3(0.0, CAP_B, 0.0)
	var t0 := rel + _tb * Vector3(0.0, CAP_A, 0.0)
	var t1 := rel + _tb * Vector3(0.0, CAP_B, 0.0)
	var dist := _seg_dist(s0, s1, t0, t1)
	if dist < HULL_R * 2.0:
		_fail("HULLS COLLIDED", "Contact at %.2f m/s. The ports were %.1f m apart sideways." % [_dk_latv.length() + absf(_dk_closing), _dk_lat.length()])


func _attempt_dock() -> void:
	var fails: Array[String] = []
	if _dk_closing > TOL_CLOSE_MAX:
		fails.append("closing speed %.2f m/s (max %.2f)" % [_dk_closing, TOL_CLOSE_MAX])
	if _dk_closing < TOL_CLOSE_MIN:
		fails.append("closing speed %.3f m/s too low to capture (min %.2f)" % [_dk_closing, TOL_CLOSE_MIN])
	if _dk_latv.length() > TOL_LAT_VEL:
		fails.append("sideways speed %.2f m/s (max %.2f)" % [_dk_latv.length(), TOL_LAT_VEL])
	if _dk_lat.length() > TOL_LAT_OFF:
		fails.append("port offset %.2f m (max %.2f)" % [_dk_lat.length(), TOL_LAT_OFF])
	if _dk_tilt > TOL_TILT_DEG:
		fails.append("axis error %.1f deg (max %.1f)" % [_dk_tilt, TOL_TILT_DEG])
	if absf(_dk_roll) > TOL_ROLL_DEG:
		fails.append("roll error %.1f deg (max %.1f)" % [absf(_dk_roll), TOL_ROLL_DEG])
	if _dk_rate > TOL_RATE_DEG:
		fails.append("relative rotation %.2f deg/s (max %.2f)" % [_dk_rate, TOL_RATE_DEG])
	if fails.is_empty():
		_dock_success()
	else:
		_fail("DOCKING FAILED: HARD CONTACT", "\n".join(PackedStringArray(fails)))


func _dock_success() -> void:
	_docked = true
	_mode = Mode.DOCKED
	if GameState.active:
		Life.complete_mission()                  # saved with the slot: the pad is empty when the moon is loaded again
	_eng = Eng.OFF
	_thrust_frac = 0.0
	_throttle = 0.0
	_in_tr = Vector3.ZERO
	_warp_idx = 0
	_end_title = "SOFT CAPTURE - HARD DOCK ACHIEVED"
	_end_text = "Time of flight  %s\nPropellant left  %.1f t  (%.0f m/s of delta-v)\nRCS propellant left  %.0f kg\nEngine starts used  %d / %d\nPort offset at contact  %.2f m\nClosing speed  %.3f m/s\n\nF5 to fly it again." % [
		_fmt_clock(_met), _prop / 1000.0, _dv_left(), _m_rcs, IGNITIONS - _ignitions, IGNITIONS, _dk_lat.length(), _dk_closing]
	_msg("SOFT CAPTURE. HARD DOCK.", 1)
	_follow_dock()


func _follow_dock() -> void:
	_att = _tb * Basis(Vector3(0.0, 0.0, 1.0), PI)
	var off := _tb * Vector3(0.0, 2.0 * NOSE_Y, 0.0)
	var off2 := _target_basis(_t + 0.1) * Vector3(0.0, 2.0 * NOSE_Y, 0.0)
	_px = _tpx + off.x
	_py = _tpy + off.y
	_pz = _tpz + off.z
	var dv := (off2 - off) / 0.1
	_vx = _tvx + dv.x
	_vy = _tvy + dv.y
	_vz = _tvz + dv.z
	_w = Vector3.ZERO


func _fail(title: String, text: String) -> void:
	if _frozen:
		return
	_frozen = true
	_mode = Mode.FAILED
	_thrust_frac = 0.0
	_end_title = "MISSION FAILED: " + title
	_end_text = text + "\n\nF5 to try again."
	_msg(title, 3)
	_ship_node.visible = false
	_flame_pivot.visible = false
	var p := CPUParticles3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 8
	sm.rings = 4
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	sm.material = mat
	p.mesh = sm
	p.amount = 160
	p.lifetime = 3.0
	p.one_shot = true
	p.explosiveness = 1.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 4.0
	p.direction = Vector3.UP
	p.spread = 180.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 5.0
	p.initial_velocity_max = 45.0
	p.scale_amount_min = 0.8
	p.scale_amount_max = 3.0
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.3, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.95, 0.7, 1.0), Color(1.0, 0.5, 0.15, 0.8), Color(0.2, 0.1, 0.05, 0.0)])
	p.color_ramp = g
	p.local_coords = true
	p.emitting = true
	add_child(p)
	_set_camera(0)
	_chase_dist = 150.0
	_update_chase_cam()


static func _seg_dist(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var c := d1.dot(r)
	var b := d1.dot(d2)
	var denom := a * e - b * b
	var s := 0.0
	if denom > 1e-9:
		s = clampf((b * f - c * e) / denom, 0.0, 1.0)
	var t := (b * s + f) / e
	if t < 0.0:
		t = 0.0
		s = clampf(-c / a, 0.0, 1.0)
	elif t > 1.0:
		t = 1.0
		s = clampf((b - c) / a, 0.0, 1.0)
	return (p1 + d1 * s).distance_to(p2 + d2 * t)


func _compute_dock_data() -> void:
	var rel := Vector3(_tpx - _px, _tpy - _py, _tpz - _pz)
	_rel_cg = rel
	var ps := _att * DOCK_PORT
	var pt := rel + _tb * DOCK_PORT
	var delta := ps - pt
	var axis := _tb.y
	_dk_a = delta.dot(axis)
	_dk_lat = delta - axis * _dk_a
	_dk_range = delta.length()
	var vrel := Vector3(_vx - _tvx, _vy - _tvy, _vz - _tvz)
	var w_s := _att * _w
	var wv := vrel + w_s.cross(ps) - _tport_vel
	_dk_closing = -wv.dot(axis)
	_dk_latv = wv - axis * wv.dot(axis)
	var tp := -delta
	_dk_off_x = tp.dot(_att.x)
	_dk_off_z = tp.dot(_att.z)
	var want := -axis
	_dk_tilt_x = rad_to_deg(asin(clampf(want.dot(_att.x), -1.0, 1.0)))
	_dk_tilt_z = rad_to_deg(asin(clampf(want.dot(_att.z), -1.0, 1.0)))
	_dk_tilt = rad_to_deg(acos(clampf(_att.y.dot(want), -1.0, 1.0)))
	var zt := _tb.z - axis * _tb.z.dot(axis)
	var zs := _att.z - axis * _att.z.dot(axis)
	_dk_roll = rad_to_deg(atan2(zt.cross(zs).dot(axis), zt.dot(zs)))
	_dk_rate = rad_to_deg((w_s - _tw).length())


# ================================================================= orbit maths

func _update_elements() -> void:
	var r := sqrt(_px * _px + _py * _py + _pz * _pz)
	var v2 := _vx * _vx + _vy * _vy + _vz * _vz
	var hx := _py * _vz - _pz * _vy
	var hy := _pz * _vx - _px * _vz
	var hz := _px * _vy - _py * _vx
	var hm := sqrt(hx * hx + hy * hy + hz * hz)
	var rv := _px * _vx + _py * _vy + _pz * _vz
	var kk := v2 - MU / r
	var ex := (kk * _px - rv * _vx) / MU
	var ey := (kk * _py - rv * _vy) / MU
	var ez := (kk * _pz - rv * _vz) / MU
	var e := sqrt(ex * ex + ey * ey + ez * ez)
	var energy := v2 * 0.5 - MU / r
	_el_valid = hm > 1.0
	_el_e = e
	_el_bound = energy < 0.0
	_el_p = hm * hm / MU
	_el_hn = Vector3(hx, hy, hz).normalized() if hm > 1.0 else Vector3.ZERO
	_el_ev = Vector3(ex, ey, ez).normalized() if e > 1e-6 else Vector3(_px, _py, _pz).normalized()
	_t_ap = -1.0
	_t_pe = -1.0
	if _el_bound:
		_el_a = -MU / (2.0 * energy)
		_el_rp = _el_a * (1.0 - e)
		_el_ra = _el_a * (1.0 + e)
		_el_T = TAU * sqrt(_el_a * _el_a * _el_a / MU)
		if e > 1e-4 and hm > 1.0:
			var cosv := clampf((ex * _px + ey * _py + ez * _pz) / (e * r), -1.0, 1.0)
			var nu := acos(cosv)
			if rv < 0.0:
				nu = TAU - nu
			var ecc_anom := 2.0 * atan2(sqrt(1.0 - e) * sin(nu * 0.5), sqrt(1.0 + e) * cos(nu * 0.5))
			var mean := fposmod(ecc_anom - e * sin(ecc_anom), TAU)
			var mm := TAU / _el_T
			_t_pe = fposmod(TAU - mean, TAU) / mm
			_t_ap = fposmod(PI - mean, TAU) / mm
	else:
		_el_a = 0.0
		_el_ra = 0.0
		_el_T = 0.0
		_el_rp = hm * hm / (MU * (1.0 + e))


func _predict_closest() -> void:
	if _landed or _docked:
		_ca_dist = -1.0
		return
	var x := _px
	var y := _py
	var z := _pz
	var vx := _vx
	var vy := _vy
	var vz := _vz
	var best := 1.0e30
	var bt := 0.0
	var dt := 6.0
	var t := _t
	for i in range(1100):
		var r2 := x * x + y * y + z * z
		if r2 < R_MOON * R_MOON:
			break
		var k := -MU / (r2 * sqrt(r2))
		vx += k * x * 0.5 * dt
		vy += k * y * 0.5 * dt
		vz += k * z * 0.5 * dt
		x += vx * dt
		y += vy * dt
		z += vz * dt
		r2 = x * x + y * y + z * z
		k = -MU / (r2 * sqrt(r2))
		vx += k * x * 0.5 * dt
		vy += k * y * 0.5 * dt
		vz += k * z * 0.5 * dt
		t += dt
		var th := _th0 + _omega * t
		var c := cos(th)
		var s := sin(th)
		var dx := TARGET_R * (c * _e1.x + s * _e2.x) - x
		var dy := TARGET_R * (c * _e1.y + s * _e2.y) - y
		var dz := TARGET_R * (c * _e1.z + s * _e2.z) - z
		var d2 := dx * dx + dy * dy + dz * dz
		if d2 < best:
			best = d2
			bt = t - _t
	_ca_dist = sqrt(best)
	_ca_t = bt


func _dv_left() -> float:
	var m := _mass()
	return ISP * G0 * log(m / (m - _prop))


func _sun_visibility() -> float:
	var proj := _px * _sun.x + _py * _sun.y + _pz * _sun.z
	if proj >= 0.0:
		return 1.0
	var qx := _px - proj * _sun.x
	var qy := _py - proj * _sun.y
	var qz := _pz - proj * _sun.z
	var perp := sqrt(qx * qx + qy * qy + qz * qz)
	return smoothstep(R_MOON - 2000.0, R_MOON + 2000.0, perp)


func _check_milestones() -> void:
	if _mode != Mode.FLIGHT:
		return
	if not _orbit_flag and _el_bound and _el_rp > R_MOON + 10000.0:
		_orbit_flag = true
		_msg("STABLE ORBIT   PE %.0f km   AP %.0f km" % [(_el_rp - R_MOON) / 1000.0, (_el_ra - R_MOON) / 1000.0], 1)


# ================================================================= world sync

func _sync_world() -> void:
	if _ship_node == null:
		return
	_ship_node.basis = _att
	_tgt_node.position = Vector3(_tpx - _px, _tpy - _py, _tpz - _pz)
	_tgt_node.basis = _tb
	_moon_mi.position = Vector3(-_px, -_py, -_pz)
	var r := sqrt(_px * _px + _py * _py + _pz * _pz)
	_cap_mi.visible = (r - R_MOON) < 80000.0
	_cap_mi.position = Vector3(_u.x * R_MOON - _px, _u.y * R_MOON - _py, _u.z * R_MOON - _pz)
	_earth_mi.position = _earth * 9.0e6

	var vis := _sun_visibility()
	_sun_light.light_energy = 1.5 * vis
	_sun_light.visible = vis > 0.001

	# engine plume
	var on := _thrust_frac > 0.02 and not _frozen
	_flame_pivot.visible = on
	if on:
		var d := Vector3(_gim.x, 1.0, _gim.y).normalized()
		var ax := Vector3(0.0, 1.0, 0.0).cross(d)
		if ax.length() > 1e-5:
			_flame_pivot.basis = Basis(ax.normalized(), acos(clampf(d.y, -1.0, 1.0)))
		else:
			_flame_pivot.basis = Basis.IDENTITY
		var s := 0.35 + 0.65 * _thrust_frac
		_flame.scale = Vector3(s * (0.95 + 0.1 * randf()), s * (0.9 + 0.2 * randf()), s * (0.95 + 0.1 * randf()))
		_engine_light.light_energy = 6.0 * _thrust_frac * float(_n_eng) / 3.0 * (0.9 + 0.2 * randf())
	else:
		_engine_light.light_energy = 0.0

	# tanker strobe
	var blink := fmod(_t, 1.6) < 0.12
	_tgt_strobe.light_energy = 6.0 if blink else 0.0

	# cameras that are not parented to the ship
	var tgt_rel := _tgt_node.position
	if _cam_mode == 2:
		var look_from := _att * Vector3(30.0, 12.0, -50.0)
		var dir := tgt_rel - look_from
		if dir.length() > 1.0:
			var hint := Vector3.UP if absf(dir.normalized().y) < 0.95 else Vector3.RIGHT
			_cam_tgt.transform = Transform3D(Basis.looking_at(dir, hint), look_from)
			_cam_tgt.fov = clampf(2.0 * rad_to_deg(atan(70.0 / maxf(dir.length(), 70.0))), 3.0, 65.0)

	# navball
	var up := Vector3(_px, _py, _pz) / r
	var east := _nt.cross(up).normalized()
	var north := up.cross(east)
	var f_basis := Basis(east, up, -north)
	var b_basis := Basis(_att.x, -_att.z, _att.y)
	_ball.basis = b_basis.transposed() * f_basis


# ================================================================= HUD

func _msg(text: String, kind: int) -> void:
	_log.append({"t": Time.get_ticks_msec() / 1000.0, "s": text, "k": kind})
	while _log.size() > 5:
		_log.pop_front()


static func _fmt_dist(m: float) -> String:
	var a := absf(m)
	if a >= 100000.0:
		return "%.0f km" % (m / 1000.0)
	if a >= 1000.0:
		return "%.2f km" % (m / 1000.0)
	return "%.1f m" % m


static func _fmt_clock(s: float) -> String:
	var t := int(maxf(s, 0.0))
	return "%02d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60]


func _phase_text() -> String:
	match _mode:
		Mode.DOCKED:
			return "DOCKED"
		Mode.FAILED:
			return "MISSION FAILED"
	if _landed:
		return "ON PAD"
	var rg := _rel_range()
	if rg < 120.0:
		return "FINAL APPROACH"
	if rg < 1500.0:
		return "PROXIMITY OPS"
	if rg < 30000.0:
		return "RENDEZVOUS"
	if _el_bound and _el_rp > R_MOON + 8000.0:
		return "IN ORBIT"
	return "ASCENT / SUBORBITAL"


func _attitude() -> Array:
	var up := Vector3(_px, _py, _pz).normalized()
	var east := _nt.cross(up).normalized()
	var north := up.cross(east)
	var nose := _att.y
	var pitch := rad_to_deg(asin(clampf(nose.dot(up), -1.0, 1.0)))
	var hdg := fposmod(rad_to_deg(atan2(nose.dot(east), nose.dot(north))), 360.0)
	var ref_up := up - nose * nose.dot(up)
	if ref_up.length() < 0.05:
		ref_up = north - nose * nose.dot(north)
	ref_up = ref_up.normalized()
	var dorsal := -_att.z
	var roll := rad_to_deg(atan2(dorsal.cross(ref_up).dot(nose), dorsal.dot(ref_up)))
	return [pitch, hdg, roll]


func _update_panels() -> void:
	if _left_lbl == null:
		return
	var r := sqrt(_px * _px + _py * _py + _pz * _pz)
	var up := Vector3(_px, _py, _pz) / r
	var vv := Vector3(_vx, _vy, _vz)
	var vr := vv.dot(up)
	var vh := sqrt(maxf(0.0, vv.length_squared() - vr * vr))
	var att := _attitude()
	var s := ""
	s += "PHASE     %s\n" % _phase_text()
	s += "MET       %s\n" % _fmt_clock(_met)
	s += "ALTITUDE  %s\n" % _fmt_dist(r - R_MOON - 20.0 if _landed else r - R_MOON)
	s += "V-SPEED   %+.1f m/s\n" % vr
	s += "H-SPEED   %.1f m/s\n" % vh
	s += "ACCEL     %.2f g(moon)\n" % (_accel / 1.62)
	if _el_bound and _el_valid and not _landed:
		s += "APOAPSIS  %s" % _fmt_dist(_el_ra - R_MOON)
		s += ("   T-%s\n" % _fmt_clock(_t_ap)) if _t_ap >= 0.0 else "\n"
		s += "PERIAPSIS %s" % _fmt_dist(_el_rp - R_MOON)
		s += ("   T-%s\n" % _fmt_clock(_t_pe)) if _t_pe >= 0.0 else "\n"
		s += "PERIOD    %s\n" % _fmt_clock(_el_T)
		s += "ECC       %.4f\n" % _el_e
		if _el_hn != Vector3.ZERO:
			var inc := rad_to_deg(acos(clampf(_el_hn.dot(_nt), -1.0, 1.0)))
			s += "REL INC   %.2f deg vs tanker\n" % inc
	elif _el_valid and not _landed:
		s += "TRAJECTORY  ESCAPE / SUBORBITAL\nPERIAPSIS %s\n" % _fmt_dist(_el_rp - R_MOON)
	s += "\nPITCH %+6.1f  HDG %05.1f  ROLL %+6.1f\n" % [att[0], att[1], att[2]]
	s += "RATES  p%+5.2f y%+5.2f r%+5.2f deg/s\n" % [-rad_to_deg(_w.x), -rad_to_deg(_w.z), -rad_to_deg(_w.y)]
	s += "\nMASS      %.1f t\n" % (_mass() / 1000.0)
	s += "PROP      %.1f t   dV %.0f m/s\n" % [_prop / 1000.0, _dv_left()]
	s += "RCS       %.0f kg\n" % _m_rcs
	s += "STARTS    %d / %d\n" % [_ignitions, IGNITIONS]
	var eng_txt: String = ["OFF", "STARTING", "RUNNING"][_eng]
	s += "ENGINES   %s x%d  %.0f%%\n" % [eng_txt, _n_eng, _thrust_frac * 100.0]
	s += "SAS %s   RCS %s   LIGHTS %s\n" % [["OFF", "DAMP", "HOLD"][_sas], "ON" if _rcs_on else "OFF", "ON" if _lights_on else "OFF"]
	var weff := _effective_warp()
	var wsel: int = WARPS[_warp_idx]
	s += "WARP      %dx%s\n" % [weff, ("  (held, %dx selected)" % wsel) if weff != wsel else ""]
	_left_lbl.text = s

	# right panel: target
	var t := ""
	t += "TANKER-1   circular %.0f km orbit\n" % (TARGET_ALT_M / 1000.0)
	if _landed and _mode == Mode.PAD:
		var lead := fposmod(_th0 + _omega * _t, TAU)
		var dtw := fposmod(_lambda - lead, TAU) / _omega
		t += "\nLAUNCH WINDOW\n"
		t += "  opens in      %s\n" % _fmt_clock(dtw)
		t += "  tanker lead   %.1f deg\n" % rad_to_deg(lead)
		t += "  best lead     %.1f deg  (+-3)\n" % rad_to_deg(_lambda)
		t += "  tanker plane  tilted %.2f deg from the pad\n" % rad_to_deg(acos(clampf(_n.dot(_nt), -1.0, 1.0)))
		t += "\nAscent profile: vertical, then pitch to the\neast; apoapsis 100 km, periapsis ~15 km.\nCircularise at apoapsis."
	else:
		var rg := _rel_range()
		var vrel := Vector3(_vx - _tvx, _vy - _tvy, _vz - _tvz)
		var rel := Vector3(_tpx - _px, _tpy - _py, _tpz - _pz)
		var closing := 0.0
		if rel.length() > 0.1:
			closing = -vrel.dot(rel.normalized())
		t += "RANGE        %s\n" % _fmt_dist(rg)
		t += "REL SPEED    %.2f m/s\n" % vrel.length()
		t += "RANGE RATE   %+.2f m/s\n" % closing
		if _ca_dist >= 0.0 and not _docked:
			t += "CLOSEST APP  %s in %s\n" % [_fmt_dist(_ca_dist), _fmt_clock(_ca_t)]
		if _el_hn != Vector3.ZERO and _el_valid:
			var th_s := atan2(py_dot(_e2), py_dot(_e1))
			var th_t := _th0 + _omega * _t
			var phase := rad_to_deg(wrapf(th_t - th_s, -PI, PI))
			t += "PHASE ANGLE  %+.2f deg (tanker ahead +)\n" % phase
	_right_lbl.text = t

	_help_lbl.get_parent().visible = _help_open
	_banner.visible = _end_title != ""
	if _banner.visible:
		_banner.text = _end_title + "\n\n" + _end_text
		var good := _mode == Mode.DOCKED
		_banner.add_theme_color_override("font_color", Color(0.5, 1.0, 0.6) if good else Color(1.0, 0.45, 0.4))


func py_dot(axis: Vector3) -> float:
	return _px * axis.x + _py * axis.y + _pz * axis.z


# ================================================================= overlay drawing

func _on_overlay_draw() -> void:
	var vs := _overlay.size
	_draw_log(vs)
	_draw_gauges(vs)
	_draw_navball_markers(vs)
	_draw_target_marker()
	if _cam_mode == 1 or (not _landed and _rel_range() < 1500.0 and not _frozen):
		if _rel_range() < 1500.0:
			_draw_docking_scope(vs)
	if _map_open:
		_draw_map(vs)


func _draw_log(vs: Vector2) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var y := 34.0
	var keep: Array = []
	for e in _log:
		if now - float(e["t"]) < 9.0:
			keep.append(e)
	_log = keep
	for e in _log:
		var kind: int = e["k"]
		var col := Color(0.85, 0.93, 1.0)
		if kind == 1:
			col = Color(0.5, 1.0, 0.6)
		elif kind == 2:
			col = Color(1.0, 0.85, 0.4)
		elif kind == 3:
			col = Color(1.0, 0.45, 0.4)
		var age := now - float(e["t"])
		col.a = clampf(1.0 - (age - 7.0) / 2.0, 0.0, 1.0)
		_overlay.draw_string(_font, Vector2(0.0, y), str(e["s"]), HORIZONTAL_ALIGNMENT_CENTER, vs.x, 18, col)
		y += 24.0


func _bar(rect: Rect2, frac: float, col: Color, label: String, value: String) -> void:
	_overlay.draw_rect(rect, Color(0, 0, 0, 0.55))
	var fh := rect.size.y * clampf(frac, 0.0, 1.0)
	_overlay.draw_rect(Rect2(rect.position.x, rect.end.y - fh, rect.size.x, fh), col)
	_overlay.draw_rect(rect, Color(0.6, 0.75, 0.9, 0.8), false, 1.0)
	_overlay.draw_string(_font, Vector2(rect.position.x - 4.0, rect.end.y + 15.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.95, 1.0))
	_overlay.draw_string(_font, Vector2(rect.position.x - 8.0, rect.position.y - 6.0), value, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.95, 1.0))


func _draw_gauges(vs: Vector2) -> void:
	var by := vs.y - 34.0
	var h := 150.0
	var cx := vs.x * 0.5
	var x0 := cx - NB_SIZE * 0.5 - 150.0
	_bar(Rect2(x0, by - h, 24.0, h), _throttle, Color(0.35, 0.8, 1.0), "THR", "%.0f%%" % (_throttle * 100.0))
	_bar(Rect2(x0 + 44.0, by - h, 24.0, h), _thrust_frac, Color(1.0, 0.7, 0.3), "ACT", "%.0f%%" % (_thrust_frac * 100.0))
	_bar(Rect2(x0 + 88.0, by - h, 24.0, h), _prop / PROP_MAX, Color(0.5, 0.9, 0.5), "PRP", "%.0ft" % (_prop / 1000.0))
	var x1 := cx + NB_SIZE * 0.5 + 40.0
	_bar(Rect2(x1, by - h, 24.0, h), _m_rcs / RCS_PROP_MAX, Color(0.9, 0.9, 0.4), "RCS", "%.0fkg" % _m_rcs)
	var ul := clampf(_ullage / ULLAGE_NEEDED_S, 0.0, 1.0)
	_bar(Rect2(x1 + 44.0, by - h, 24.0, h), ul, Color(0.8, 0.5, 1.0), "ULL", "%.0f%%" % (ul * 100.0))
	# gimbal indicator
	var gc := Vector2(x1 + 120.0, by - h * 0.5)
	_overlay.draw_rect(Rect2(gc - Vector2(32, 32), Vector2(64, 64)), Color(0, 0, 0, 0.55))
	_overlay.draw_rect(Rect2(gc - Vector2(32, 32), Vector2(64, 64)), Color(0.6, 0.75, 0.9, 0.8), false, 1.0)
	_overlay.draw_line(gc - Vector2(32, 0), gc + Vector2(32, 0), Color(1, 1, 1, 0.25), 1.0)
	_overlay.draw_line(gc - Vector2(0, 32), gc + Vector2(0, 32), Color(1, 1, 1, 0.25), 1.0)
	var gp := gc + Vector2(_gim.x, _gim.y) / GIMBAL_MAX * 28.0
	_overlay.draw_circle(gp, 4.0, Color(1.0, 0.7, 0.3))
	_overlay.draw_string(_font, gc + Vector2(-20, 48), "GIMBAL", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.95, 1.0))
	if _rcs_active:
		_overlay.draw_string(_font, Vector2(x1 - 4.0, by - h - 24.0), "RCS FIRING", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 1.0, 0.5))


func _to_ball(d: Vector3) -> Vector3:
	return Vector3(d.dot(_att.x), -d.dot(_att.z), d.dot(_att.y))


func _nb_marker(d: Vector3, label: String, col: Color, shape: int) -> void:
	if d.length() < 0.5:
		return
	var vs := _overlay.size
	var center := Vector2(vs.x * 0.5, vs.y - 8.0 - NB_SIZE * 0.5)
	var rad := NB_SIZE / 2.1
	var v := _to_ball(d.normalized())
	var p := center + Vector2(v.x, -v.y) * rad
	var c := col
	if v.z < 0.0:
		c.a = 0.28
	match shape:
		0:
			_overlay.draw_arc(p, 8.0, 0.0, TAU, 20, c, 2.0)
			_overlay.draw_circle(p, 2.0, c)
		1:
			_overlay.draw_arc(p, 8.0, 0.0, TAU, 20, c, 2.0)
			_overlay.draw_line(p + Vector2(-6, -6), p + Vector2(6, 6), c, 2.0)
			_overlay.draw_line(p + Vector2(-6, 6), p + Vector2(6, -6), c, 2.0)
		2:
			_overlay.draw_colored_polygon(PackedVector2Array([p + Vector2(0, -9), p + Vector2(8, 6), p + Vector2(-8, 6)]), c)
		3:
			_overlay.draw_arc(p, 8.0, 0.0, TAU, 20, c, 2.0)
			_overlay.draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), c, 2.0)
		_:
			var s := 7.0
			_overlay.draw_polyline(PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0), p + Vector2(0, -s)]), c, 2.0)
	_overlay.draw_string(_font, p + Vector2(10, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, c)


func _draw_navball_markers(vs: Vector2) -> void:
	var center := Vector2(vs.x * 0.5, vs.y - 8.0 - NB_SIZE * 0.5)
	var rad := NB_SIZE / 2.1
	_overlay.draw_arc(center, rad + 1.0, 0.0, TAU, 64, Color(0.8, 0.9, 1.0, 0.6), 2.0)
	# nose reticle
	_overlay.draw_arc(center, 9.0, 0.0, TAU, 20, Color(1.0, 0.8, 0.2), 2.0)
	_overlay.draw_line(center + Vector2(-22, 0), center + Vector2(-9, 0), Color(1.0, 0.8, 0.2), 2.0)
	_overlay.draw_line(center + Vector2(22, 0), center + Vector2(9, 0), Color(1.0, 0.8, 0.2), 2.0)
	_overlay.draw_line(center + Vector2(0, -9), center + Vector2(0, -20), Color(1.0, 0.8, 0.2), 2.0)

	var r := sqrt(_px * _px + _py * _py + _pz * _pz)
	var up := Vector3(_px, _py, _pz) / r
	var east := _nt.cross(up).normalized()
	var north := up.cross(east)
	_nb_marker(north, "N", Color(1.0, 0.4, 0.4), 4)
	_nb_marker(east, "E", Color(0.9, 0.9, 0.9), 4)
	_nb_marker(-north, "S", Color(0.9, 0.9, 0.9), 4)
	_nb_marker(-east, "W", Color(0.9, 0.9, 0.9), 4)

	if _landed:
		return
	var vv := Vector3(_vx, _vy, _vz)
	if not _ball_target_mode:
		if vv.length() > 0.5:
			var vn := vv.normalized()
			_nb_marker(vn, "PRO", Color(0.6, 1.0, 0.4), 0)
			_nb_marker(-vn, "RET", Color(0.6, 1.0, 0.4), 1)
			if _el_hn != Vector3.ZERO:
				_nb_marker(_el_hn, "NRM", Color(0.8, 0.5, 1.0), 2)
				_nb_marker(-_el_hn, "ANT", Color(0.8, 0.5, 1.0), 2)
			var rad_dir := up - vn * up.dot(vn)
			if rad_dir.length() > 0.01:
				_nb_marker(rad_dir, "R+", Color(0.4, 0.9, 1.0), 3)
				_nb_marker(-rad_dir, "R-", Color(0.4, 0.9, 1.0), 3)
	else:
		var rel := Vector3(_tpx - _px, _tpy - _py, _tpz - _pz)
		var vrel := Vector3(_vx - _tvx, _vy - _tvy, _vz - _tvz)
		_nb_marker(rel, "TGT", Color(1.0, 0.6, 0.2), 0)
		_nb_marker(-rel, "-TGT", Color(1.0, 0.6, 0.2), 1)
		if vrel.length() > 0.02:
			_nb_marker(vrel, "VR+", Color(0.4, 1.0, 1.0), 0)
			_nb_marker(-vrel, "VR-", Color(0.4, 1.0, 1.0), 1)
	_overlay.draw_string(_font, center + Vector2(-rad, -rad - 6.0), "MARKERS: " + ("TARGET" if _ball_target_mode else "ORBIT"), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.9, 1.0, 0.8))


func _draw_target_marker() -> void:
	if _cam == null or _tgt_node == null or _frozen:
		return
	var p := _tgt_node.position
	if _cam.is_position_behind(p):
		return
	var sp := _cam.unproject_position(p)
	var vs := _overlay.size
	if sp.x < 0.0 or sp.y < 0.0 or sp.x > vs.x or sp.y > vs.y:
		return
	var col := Color(1.0, 0.6, 0.2)
	var rg := p.length()
	if rg > 300.0:
		var s := 14.0
		_overlay.draw_polyline(PackedVector2Array([sp + Vector2(0, -s), sp + Vector2(s, 0), sp + Vector2(0, s), sp + Vector2(-s, 0), sp + Vector2(0, -s)]), col, 2.0)
	_overlay.draw_string(_font, sp + Vector2(18, 4), "TANKER  " + _fmt_dist(rg), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col)


func _scope_dot(center: Vector2, size: float, scale_val: float, vx: float, vy: float, col: Color, title: String) -> void:
	var half := size * 0.5
	_overlay.draw_rect(Rect2(center - Vector2(half, half), Vector2(size, size)), Color(0, 0, 0, 0.55))
	_overlay.draw_rect(Rect2(center - Vector2(half, half), Vector2(size, size)), Color(0.6, 0.75, 0.9, 0.8), false, 1.0)
	_overlay.draw_line(center - Vector2(half, 0), center + Vector2(half, 0), Color(1, 1, 1, 0.3), 1.0)
	_overlay.draw_line(center - Vector2(0, half), center + Vector2(0, half), Color(1, 1, 1, 0.3), 1.0)
	_overlay.draw_arc(center, half * 0.25, 0.0, TAU, 20, Color(0.3, 1.0, 0.5, 0.6), 1.0)
	var p := center + Vector2(clampf(vx / scale_val, -1.0, 1.0), clampf(vy / scale_val, -1.0, 1.0)) * (half - 4.0)
	_overlay.draw_circle(p, 5.0, col)
	_overlay.draw_string(_font, center + Vector2(-half, half + 14.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.95, 1.0))


func _draw_docking_scope(vs: Vector2) -> void:
	_compute_dock_data()
	var good := Color(0.4, 1.0, 0.5)
	var bad := Color(1.0, 0.45, 0.4)
	var x := vs.x - 280.0
	var y := vs.y * 0.5 - 150.0
	_overlay.draw_rect(Rect2(x - 12.0, y - 24.0, 276.0, 330.0), Color(0, 0.02, 0.05, 0.6))
	_overlay.draw_string(_font, Vector2(x, y - 4.0), "DOCKING", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1.0, 0.8, 0.3))
	var lat_speed := _dk_latv.length()
	var rows := [
		["PORT RANGE", "%s" % _fmt_dist(_dk_range), true],
		["CLOSING", "%+.3f m/s  (%.2f-%.2f)" % [_dk_closing, TOL_CLOSE_MIN, TOL_CLOSE_MAX], _dk_closing >= TOL_CLOSE_MIN and _dk_closing <= TOL_CLOSE_MAX],
		["SIDE SPEED", "%.3f m/s  (<%.2f)" % [lat_speed, TOL_LAT_VEL], lat_speed <= TOL_LAT_VEL],
		["PORT OFFSET", "%.2f m  (<%.1f)" % [_dk_lat.length(), TOL_LAT_OFF], _dk_lat.length() <= TOL_LAT_OFF],
		["AXIS ERROR", "%.1f deg  (<%.0f)" % [_dk_tilt, TOL_TILT_DEG], _dk_tilt <= TOL_TILT_DEG],
		["ROLL ERROR", "%+.1f deg  (<%.0f)" % [_dk_roll, TOL_ROLL_DEG], absf(_dk_roll) <= TOL_ROLL_DEG],
		["REL ROTATION", "%.2f deg/s  (<%.2f)" % [_dk_rate, TOL_RATE_DEG], _dk_rate <= TOL_RATE_DEG],
	]
	var yy := y + 18.0
	for row in rows:
		var ok: bool = row[2]
		_overlay.draw_string(_font, Vector2(x, yy), "%-12s %s" % [row[0], row[1]], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, good if ok else bad)
		yy += 18.0
	# offset scope: where the tanker's port is relative to your nose axis (move toward the dot)
	_scope_dot(Vector2(x + 60.0, y + 210.0), 110.0, maxf(2.0, _dk_range * 0.3), _dk_off_x, _dk_off_z, Color(1.0, 0.6, 0.2), "PORT OFFSET")
	# attitude scope: where the tanker's axis should be relative to your nose (rotate toward the dot)
	_scope_dot(Vector2(x + 190.0, y + 210.0), 110.0, 10.0, _dk_tilt_x, _dk_tilt_z, Color(0.5, 0.9, 1.0), "ATT ERROR")
	# the nose camera shows the port with a lock ring
	if _cam != null and _tgt_node != null:
		var pw := _tgt_node.position + _tb * DOCK_PORT
		if not _cam.is_position_behind(pw):
			var sp := _cam.unproject_position(pw)
			var cc := vs * 0.5
			_overlay.draw_arc(sp, 16.0, 0.0, TAU, 28, Color(1.0, 0.6, 0.2), 2.0)
			_overlay.draw_line(cc, sp, Color(1.0, 0.6, 0.2, 0.4), 1.0)
	if _cam_mode == 1:
		var c2 := vs * 0.5
		_overlay.draw_line(c2 + Vector2(-30, 0), c2 + Vector2(-8, 0), Color(0.4, 1.0, 0.5, 0.8), 1.5)
		_overlay.draw_line(c2 + Vector2(30, 0), c2 + Vector2(8, 0), Color(0.4, 1.0, 0.5, 0.8), 1.5)
		_overlay.draw_line(c2 + Vector2(0, -30), c2 + Vector2(0, -8), Color(0.4, 1.0, 0.5, 0.8), 1.5)
		_overlay.draw_line(c2 + Vector2(0, 30), c2 + Vector2(0, 8), Color(0.4, 1.0, 0.5, 0.8), 1.5)


func _draw_map(vs: Vector2) -> void:
	var side := minf(vs.x, vs.y) * 0.8
	var c := vs * 0.5
	_overlay.draw_rect(Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), Color(0, 0.01, 0.03, 0.82))
	_overlay.draw_rect(Rect2(c - Vector2(side, side) * 0.5, Vector2(side, side)), Color(0.5, 0.65, 0.85, 0.8), false, 2.0)
	var ext := TARGET_R * 1.25
	if _el_bound and _el_ra * 1.1 > ext and _el_ra < 8.0e6:
		ext = _el_ra * 1.1
	var sc := side * 0.5 / ext
	_overlay.draw_circle(c, R_MOON * sc, Color(0.35, 0.35, 0.38))
	_overlay.draw_arc(c, TARGET_R * sc, 0.0, TAU, 128, Color(1.0, 0.6, 0.2, 0.9), 1.5)

	# ship orbit
	if _el_valid and _el_hn != Vector3.ZERO and _el_e < 5.0:
		var q := _el_hn.cross(_el_ev)
		var pts := PackedVector2Array()
		var nmax := 180
		var nu_lim := TAU
		var start := 0.0
		if not _el_bound:
			nu_lim = 2.0 * acos(-1.0 / maxf(_el_e, 1.0001)) * 0.96
			start = -nu_lim * 0.5
		for i in range(nmax + 1):
			var nu := start + nu_lim * float(i) / float(nmax)
			var rr := _el_p / (1.0 + _el_e * cos(nu))
			if rr < 0.0 or rr > 3.0e7:
				continue
			var pos := (_el_ev * cos(nu) + q * sin(nu)) * rr
			pts.append(c + Vector2(pos.dot(_e1), -pos.dot(_e2)) * sc)
		if pts.size() > 1:
			_overlay.draw_polyline(pts, Color(0.4, 0.9, 1.0, 0.95), 1.5)
		if _el_bound:
			var ap := -_el_ev * _el_ra
			var pe := _el_ev * _el_rp
			var pa := c + Vector2(ap.dot(_e1), -ap.dot(_e2)) * sc
			var pp := c + Vector2(pe.dot(_e1), -pe.dot(_e2)) * sc
			_overlay.draw_circle(pa, 3.0, Color(0.4, 0.9, 1.0))
			_overlay.draw_string(_font, pa + Vector2(6, -4), "AP", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.4, 0.9, 1.0))
			_overlay.draw_circle(pp, 3.0, Color(0.4, 0.9, 1.0))
			_overlay.draw_string(_font, pp + Vector2(6, -4), "PE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.4, 0.9, 1.0))

	var padp := _u * R_MOON
	_overlay.draw_circle(c + Vector2(padp.dot(_e1), -padp.dot(_e2)) * sc, 3.0, Color(0.9, 0.9, 0.9))
	var sp := Vector3(_px, _py, _pz)
	var tp := Vector3(_tpx, _tpy, _tpz)
	var ps := c + Vector2(sp.dot(_e1), -sp.dot(_e2)) * sc
	var pt := c + Vector2(tp.dot(_e1), -tp.dot(_e2)) * sc
	_overlay.draw_circle(ps, 5.0, Color(0.4, 0.9, 1.0))
	_overlay.draw_string(_font, ps + Vector2(8, -6), "SHIP", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.4, 0.9, 1.0))
	_overlay.draw_circle(pt, 5.0, Color(1.0, 0.6, 0.2))
	_overlay.draw_string(_font, pt + Vector2(8, -6), "TANKER", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.6, 0.2))
	_overlay.draw_string(_font, c - Vector2(side * 0.5 - 12.0, side * 0.5 - 24.0), "ORBIT MAP  (projected on the tanker's orbital plane)   M closes", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.85, 0.95, 1.0))
