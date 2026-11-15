extends Node
## Autoload "Story": the dialogue plan (MOON SURVIVAL - COMPLETE DIALOGUE PLAN) as one-time story beats.
##
## Every beat plays once per slot: its flag ("story_<id>") is kept in the Repairs flags, so it is saved with the
## slot. A slot that already has repair progress when this script first runs is treated as past the early beats
## (see _migrate), so old saves do not replay the opening.
##
##   PHASE 1  before the crash       before_crash() / landing_failure()   called by landing_sequence.gd
##   PHASE 2  the crash              "crash"       when the planet scene first loads: wakes up, first radio call
##   PHASE 3  exploring              "explore"     first time 80 m from the wreck
##                                   "supplies"    first time at the wreck (the supplies that survived)
##                                   "crater" / "mountain"   terrain sampled around the player (see _check_terrain)
##                                   "oxygen"      first low-oxygen warning (Life calls oxygen_low())
##   PHASE 4  the colony (the base)  "colony"      first sight of the base
##                                   "entered"     first time inside it
##                                   "map"         first time the nav slate (N) is opened inside it
##   PHASE 5  rovers                 "left"        first time out of the base again
##                                   lost lines    while dead-reckoning has drifted and no rover has been found
##                                   "rover"       first rover found, then the rover inspection lines
##   PHASE 6  "comms"                radio restored, once the colony AND a rover have been reached
##   "spacecraft"                    first sight of the return spacecraft
##
## The repair, salvage and launch lines of the plan live where those things happen (repairs.gd STAGE_INTRO and
## repair(), return_rocket.gd and orbital_docking.gd). The plan's line "Once I leave, I won't have access to this
## map" is not used: the nav slate stays with the astronaut.
## The Lunar Colony is the base. The direction mission control gives is the real bearing from the crash site to it.

const MC := "Mission Control"
const SUIT := "Suit computer"
const AST := "Astronaut"

const CHECK_S := 1.0
const TERRAIN_S := 4.0
const EXPLORE_M := 80.0
const SUPPLIES_M := 15.0
const COLONY_SIGHT_M := 220.0
const ROVER_SEEN_M := 45.0
const SPACECRAFT_SEEN_M := 70.0
const MAP_NUDGE_S := 45.0                     # inside the base this long without opening the slate
const LOST_COOLDOWN_S := 150.0
const LOST_MIN_RUN_M := 250.0                 # dead-reckoned distance since the last fix before "lost" lines play
const LOST_MAX_LINES := 4
const COMMS_DELAY_S := 12.0

# Terrain sampling (metres). Tune these if craters or mountains are reported too often or never.
const BOWL_RING_M := 400.0
const BOWL_DEPTH_M := 30.0                    # the ring is this much higher than the player: standing in a crater
const FAR_RING_M := 1200.0
const FAR_RELIEF_M := 200.0                   # something this much higher than the player within FAR_RING_M

const LOST_LINES := [
	"This doesn't look like the formation I remember.",
	"Have I taken the wrong route?",
	"I need to reconsider my surroundings.",
	"That crater looks familiar...",
]

var _was_in := false
var _t := 0.0
var _check_cd := 0.0
var _terrain_cd := 0.0
var _lost_cd := 0.0
var _lost_count := 0
var _entered_t := -1.0
var _comms_at := -1.0
var _nudged := false
var _was_inside := false


# ================================================================= beats (the plan's text)

## PHASE 1, 1: the call before the landing. Short enough to finish before the meteor strikes (about 9.6 s).
func before_crash() -> void:
	Dialogue.clear()
	_play([
		[MC, "Astronaut, this is Earth Mission Control. Do you read us?", 2.0],
		[AST, "Loud and clear. All systems are operational.", 1.8],
		[MC, "Your lunar landing sequence begins in approximately two minutes. Remember, your primary objective is to reach the Lunar Research Colony.", 3.2],
		[AST, "Understood. Beginning descent preparation.", 1.4],
		[MC, "Good luck. We'll be monitoring your progress.", 1.5],
	])


## PHASE 1, 2: the landing failure (the meteor strike). Replaces whatever is still being said.
func landing_failure() -> void:
	_play([
		[MC, "We're detecting unusual fluctuations in your landing system.", 3.0],
		[AST, "I'm experiencing control instability!", 2.2],
		[MC, "Attempting to stabilise your descent. Hold on!", 2.6],
		[AST, "I can't maintain control!", 2.0],
		[MC, "Emergency! We're losing your signal!", 2.6],
	], true)


## PHASE 2, 3 and 4: waking up, then the first call.
func _wake_and_call() -> void:
	_play([
		[AST, "What happened? Where am I?", 2.5],
		[AST, "Mission Control, can anyone hear me?", 3.0],
		[AST, "My spacecraft... it's completely damaged.", 3.4],
	])
	var dir := _colony_direction()
	var where := "The Lunar Colony is located %s of your crash site." % dir if dir != "" else "The Lunar Colony is within a few kilometres of your crash site."
	_play([
		[AST, "Mission Control, this is the astronaut. Do you copy?", 0.0],
		[MC, "We read you! Thank goodness you're alive.", 0.0],
		[AST, "My spacecraft has crashed. I don't recognise this area.", 0.0],
		[MC, "Our telemetry indicates that your spacecraft is near the lunar surface. Unfortunately, we cannot determine your exact position.", 0.0],
		[AST, "What am I supposed to do?", 0.0],
		[MC, "Your immediate objective is to reach the Lunar Colony. We have one piece of geographical information for you.", 0.0],
		[AST, "Go ahead.", 0.0],
		[MC, where, 0.0],
		[AST, "Understood. I'll try to find it.", 0.0],
		[MC, "Your communication equipment is damaged. We may not be able to maintain contact. Conserve your resources.", 0.0],
	])


func _explore() -> void:
	_play([
		[AST, "This landscape looks completely unfamiliar.", 0.0],
		[AST, "I need to figure out which direction leads to the colony.", 0.0],
		[AST, "The shadows might help me establish my orientation.", 0.0],
	])


func _supplies() -> void:
	_play([
		[AST, "Some supplies survived the crash.", 0.0],
		[AST, "I should collect whatever I can find.", 0.0],
		[AST, "These resources might be useful later.", 0.0],
	])


func _crater() -> void:
	_play([[AST, "That crater looks enormous.", 0.0], [AST, "I should remember this location.", 0.0]])


func _mountain() -> void:
	_play([[AST, "There seems to be a mountain formation in the distance.", 0.0], [AST, "I should remember this location.", 0.0]])


## Life calls this at the first low-oxygen warning (PHASE 3, 8); later ones are the short line.
func oxygen_low() -> void:
	if _seen("oxygen"):
		Dialogue.say("Oxygen low. Head back to the base to refill.", 4.0, SUIT)
		return
	_mark("oxygen")
	_play([
		[SUIT, "Warning. Oxygen reserves are decreasing.", 0.0],
		[AST, "I need to find shelter before my supplies run out.", 0.0],
		[SUIT, "Recommended action: Continue towards the designated survival objective.", 0.0],
	])


func _colony_sight() -> void:
	_play([
		[AST, "Wait... is that the Lunar Colony?", 0.0],
		[AST, "I think I've actually found it!", 0.0],
		[MC, "Astronaut... we're detecting your proximity to the colony.", 0.0],
		[AST, "Mission accomplished. I'm approaching the entrance.", 0.0],
	])


func _entered() -> void:
	_play([
		[AST, "This place looks deserted.", 0.0],
		[AST, "There must be some surviving equipment here.", 0.0],
		[AST, "I should check the control room.", 0.0],
	])


func _map() -> void:
	_play([
		[AST, "A lunar surface map!", 0.0],
		[AST, "This shows the surrounding terrain, research locations and rover positions.", 0.0],
		[SUIT, "Multiple exploration vehicles detected in the surrounding region.", 0.0],
		[AST, "I need to remember these formations. Every landmark could help me identify my location later.", 0.0],
	])


func _left() -> void:
	_play([
		[AST, "I've studied the map. I think I know where the rovers are located.", 0.0],
		[AST, "Time to put my memory to the test.", 0.0],
		[SUIT, "Navigation assistance unavailable. Manual terrain identification required.", 0.0],
	])


func _rover() -> void:
	_play([
		[AST, "There it is! The first rover!", 0.0],
		[AST, "I actually managed to locate it using the map.", 0.0],
		[SUIT, "Rover located. Assessing vehicle condition.", 0.0],
		[AST, "The rover is damaged. I'll need to inspect its systems.", 0.0],
		[SUIT, "Vehicle diagnostics indicate multiple damaged components.", 0.0],
	])


func _comms() -> void:
	_play([
		[AST, "Mission Control, do you read me?", 0.0],
		[MC, "We read you! We've been trying to re-establish communication.", 0.0],
		[AST, "I've reached the colony and located the exploration rovers.", 0.0],
		[MC, "Excellent work. Your survival chances have improved significantly.", 0.0],
		[AST, "There's still a lot to accomplish out here.", 0.0],
	])


func _spacecraft() -> void:
	_play([
		[AST, "There's the return spacecraft. Now I need to check the damage.", 0.0],
		[SUIT, "Spacecraft inspection initiated.", 0.0],
	])


# ================================================================= driver

func _process(delta: float) -> void:
	var playing := GameState.active and GameState.in_game
	if not playing:
		_was_in = false
		return
	if not _was_in:
		_was_in = true
		_begin()
	_t += delta
	_check_slate()
	_check_cd -= delta
	if _check_cd <= 0.0:
		_check_cd = CHECK_S
		_check()
	_terrain_cd -= delta
	if _terrain_cd <= 0.0:
		_terrain_cd = TERRAIN_S
		_check_terrain()


func _begin() -> void:
	_t = 0.0
	_check_cd = 2.0
	_terrain_cd = 20.0
	_lost_cd = LOST_COOLDOWN_S
	_lost_count = 0
	_entered_t = -1.0
	_comms_at = -1.0
	_nudged = false
	_was_inside = false
	if not _seen("crash"):
		if _has_progress():
			_migrate()
		else:
			_mark("crash")
			_wake_and_call()


func _check() -> void:
	var p := _player()
	if p == null:
		return

	# --- PHASE 3
	if not _seen("explore") and LandingSite.has_wreck() and LandingSite.distance_to_wreck(p.global_position) > EXPLORE_M:
		_mark("explore")
		_explore()
	if not _seen("supplies") and LandingSite.has_wreck() and LandingSite.distance_to_wreck(p.global_position) < SUPPLIES_M:
		_mark("supplies")
		_supplies()

	# --- PHASE 4 / 5: the colony (the base)
	var base := _node("InteriorBase")
	if base != null:
		var inside := bool(base.get("player_inside"))
		if not _seen("colony") and not inside and p.global_position.distance_to(base.global_position) < COLONY_SIGHT_M:
			_mark("colony")
			_colony_sight()
		if inside and not _was_inside:
			_entered_t = _t
			if not _seen("entered"):
				_mark("entered")
				_entered()
		elif not inside and _was_inside:
			_entered_t = -1.0
			if _seen("entered") and not _seen("left"):
				_mark("left")
				_left()
		_was_inside = inside
		# Nudge towards the nav slate (the map) if it has not been opened after a while inside.
		if inside and _entered_t >= 0.0 and not _seen("map") and not _nudged and _t - _entered_t > MAP_NUDGE_S:
			_nudged = true
			Dialogue.say("The nav slate (N) holds mission control's chart: the crash site, the base and the rover drop points.", 6.0, SUIT)

	# --- PHASE 5: rovers
	if not _seen("rover"):
		for n in get_tree().get_nodes_in_group("interactible"):
			if n is Node3D and str(n.name).begins_with("Rover1_") and (n as Node3D).global_position.distance_to(p.global_position) < ROVER_SEEN_M:
				_mark("rover")
				_rover()
				break
		_check_lost()

	# --- PHASE 6: radio restored once the colony and a rover have both been reached
	if _seen("rover") and _seen("entered") and not _seen("comms"):
		if _comms_at < 0.0:
			_comms_at = _t + COMMS_DELAY_S
		elif _t >= _comms_at and not Dialogue.is_showing():
			_mark("comms")
			_comms()

	# --- the return spacecraft
	if not _seen("spacecraft"):
		var rocket := _node("ReturnRocket")
		if rocket != null and rocket.visible and rocket.global_position.distance_to(p.global_position) < SPACECRAFT_SEEN_M:
			_mark("spacecraft")
			_spacecraft()


func _check_slate() -> void:
	if _seen("map") or not _seen("entered") or not NavSlate.is_open():
		return
	var base := _node("InteriorBase")
	if base != null and bool(base.get("player_inside")):
		_mark("map")
		_map()


# Dead reckoning has drifted and no rover is found yet: the astronaut doubts the route, now and then.
func _check_lost() -> void:
	if not _seen("left") or _lost_count >= LOST_MAX_LINES:
		return
	_lost_cd -= CHECK_S
	if _lost_cd > 0.0 or LunarNav.since_fix_m() < LOST_MIN_RUN_M:
		return
	_lost_cd = LOST_COOLDOWN_S
	Dialogue.say(str(LOST_LINES[_lost_count % LOST_LINES.size()]), 0.0, AST)
	_lost_count += 1


# Samples the terrain radius around the player: a ring much higher than the player means a crater bowl, a far
# point much higher means mountains in the distance.
func _check_terrain() -> void:
	if _seen("crater") and _seen("mountain"):
		return
	var moon := MoonPlanet.instance
	var p := _player()
	if moon == null or p == null or not moon.has_method("_ground_point") or not moon.has_method("_lonlat_offset"):
		return
	if Dialogue.is_showing():
		return
	var ll := _player_lonlat(moon, p)
	var h0 := _radius_at(moon, ll.x, ll.y)
	if not _seen("crater"):
		var sum := 0.0
		for i in 8:
			var o: Array = moon._lonlat_offset(ll.x, ll.y, BOWL_RING_M, TAU * float(i) / 8.0)
			sum += _radius_at(moon, float(o[0]), float(o[1]))
		if sum / 8.0 - h0 > BOWL_DEPTH_M:
			_mark("crater")
			_crater()
			return
	if not _seen("mountain"):
		for i in 8:
			var o: Array = moon._lonlat_offset(ll.x, ll.y, FAR_RING_M, TAU * float(i) / 8.0)
			if _radius_at(moon, float(o[0]), float(o[1])) - h0 > FAR_RELIEF_M:
				_mark("mountain")
				_mountain()
				return


# ================================================================= helpers

func _seen(id: String) -> bool:
	return Repairs.has_flag("story_" + id)


func _mark(id: String) -> void:
	Repairs.set_flag("story_" + id)


func _player() -> MoonPlayer:
	return get_tree().get_first_node_in_group("player") as MoonPlayer


func _node(node_name: String) -> Node3D:
	if MoonPlanet.instance == null:
		return null
	return MoonPlanet.instance.get_node_or_null(node_name) as Node3D


# [[speaker, text, seconds], ...]: seconds 0 = reading time from the text length. interrupt: the first line
# replaces whatever is showing.
func _play(lines: Array, interrupt := false) -> void:
	var first := interrupt
	for line in lines:
		var secs := float(line[2]) if line.size() > 2 else 0.0
		Dialogue.say(str(line[1]), secs, str(line[0]), first)
		first = false


# Is this slot already past the opening? (A slot saved before the story existed.)
func _has_progress() -> bool:
	for r in Repairs.REPAIRS:
		if Repairs.is_done(str(r["id"])):
			return true
	return Repairs.is_salvaged("wreck") or Repairs.is_salvaged("InteriorBase")


func _migrate() -> void:
	for id in ["crash", "explore", "supplies", "colony", "entered", "map", "left", "rover", "comms"]:
		_mark(id)


# "northeast" etc.: the real bearing from the crash site to the base, from the coordinates mission control published.
func _colony_direction() -> String:
	var a: Dictionary = LunarNav.point_row("crash")
	var b: Dictionary = LunarNav.point_row("base")
	if not (bool(a.get("known", false)) and bool(b.get("known", false))):
		return ""
	var r: Dictionary = LunarNav.solve(float(a["lat_deg"]), float(a["lon_deg"]), float(b["lat_deg"]), float(b["lon_deg"]))
	var names := ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
	return names[int(round(float(r["bearing_deg"]) / 45.0)) % 8]


# Player position as [lon, lat] in degrees (the floating origin is added back, as navigation.gd does).
func _player_lonlat(moon: MoonPlanet, p: Node3D) -> Vector2:
	var off: Array = moon._off
	var x := float(off[0]) + p.global_position.x
	var y := float(off[1]) + p.global_position.y
	var z := float(off[2]) + p.global_position.z
	var r := maxf(sqrt(x * x + y * y + z * z), 1.0)
	return Vector2(rad_to_deg(atan2(x, z)), rad_to_deg(asin(clampf(y / r, -1.0, 1.0))))


# Distance from the planet's centre to the terrain surface at a lon / lat (degrees).
func _radius_at(moon: MoonPlanet, lon_deg: float, lat_deg: float) -> float:
	var lo := deg_to_rad(lon_deg)
	var la := deg_to_rad(lat_deg)
	var dir: Array = [cos(la) * sin(lo), sin(la), cos(la) * cos(lo)]
	var g: Array = moon._ground_point(dir)
	var x := float(g[0])
	var y := float(g[1])
	var z := float(g[2])
	return sqrt(x * x + y * y + z * z)
