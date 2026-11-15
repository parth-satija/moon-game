extends WorldSite
## The lunar base. It is still a salvage site (salvage_id "InteriorBase", set in the scene), and it now has an
## airlock to go in and out through.
##
## The hall stands on a raised floor, so the player does not walk in: they use one of two doors (base_door.gd).
##     airlock module on the outside of the +Z end   E: "Enter the base"
##     hatch on the inside of the same end           E: "Exit the base"
## Using one fades to black, moves the player to the Marker3D on the other side (OutsideSpot / InsideSpot, in
## this node's frame; -Z of a marker is the way the player ends up facing) and fades back in.
## The doors, the airlock module and both markers are ordinary nodes in interior_base.tscn: drag them in the
## editor if the doorway should be somewhere else.
##
## GameState saves whether the player is inside, and puts them back inside on load (enter_instantly).

signal entered
signal exited

const FADE_IN_S := 0.35
const HOLD_S := 0.3
const FADE_OUT_S := 0.4

## True while the player is inside the hall.
var player_inside := false

var _busy := false

@onready var _inside_spot: Node3D = $InsideSpot
@onready var _outside_spot: Node3D = $OutsideSpot


func _ready() -> void:
	super._ready()
	add_to_group("oxygen_station")


## Oxygen refill (fraction of a full tank per second) for a player at world_pos, polled by Life: only while the
## player is inside the hall. Fast once the base is repaired, a slow trickle from the emergency reserve before that.
func oxygen_rate_at(_pos: Vector3) -> float:
	if not player_inside:
		return 0.0
	return 1.0 / 20.0 if Repairs.stage_complete("base") else 1.0 / 150.0


## E on the airlock outside.
func enter(player: Node) -> void:
	_cycle(player, true)


## E on the hatch inside.
func leave(player: Node) -> void:
	_cycle(player, false)


## Puts the player inside with no fade (used when a saved game is loaded).
func enter_instantly(player: Node) -> void:
	if player is MoonPlayer:
		_place(player as MoonPlayer, _inside_spot)
		player_inside = true


func _cycle(player: Node, going_in: bool) -> void:
	if _busy or not (player is MoonPlayer):
		return
	var p := player as MoonPlayer
	if p.vehicle != null:
		Dialogue.say("Park the buggy first.", 2.5)
		return
	_busy = true
	p.set_physics_process(false)                  # no walking away mid-cycle
	Dialogue.say("Cycling the airlock...", 1.6)

	var layer := CanvasLayer.new()
	layer.layer = 50
	var rect := ColorRect.new()
	rect.color = Color(0.0, 0.0, 0.0, 0.0)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	add_child(layer)                              # a child of the base, so it goes if the scene does

	var tw := create_tween()
	tw.tween_property(rect, "color:a", 1.0, FADE_IN_S)
	tw.tween_callback(_move_player.bind(p, going_in))
	tw.tween_interval(HOLD_S)
	tw.tween_property(rect, "color:a", 0.0, FADE_OUT_S)
	tw.tween_callback(_finish_cycle.bind(layer, p))


func _move_player(p: MoonPlayer, going_in: bool) -> void:
	if not is_instance_valid(p):
		return
	_place(p, _inside_spot if going_in else _outside_spot)
	player_inside = going_in
	if going_in:
		entered.emit()
	else:
		exited.emit()


func _finish_cycle(layer: Node, p: MoonPlayer) -> void:
	layer.queue_free()
	if is_instance_valid(p):
		p.set_physics_process(true)
	_busy = false


func _place(p: MoonPlayer, spot: Node3D) -> void:
	var up := p.up_direction
	var face := -spot.global_basis.z
	face -= up * face.dot(up)
	if face.length_squared() < 1e-6:
		face = -p.global_basis.z
		face -= up * face.dot(up)
	p.global_position = spot.global_position
	p.velocity = Vector3.ZERO
	p.global_basis = Basis.looking_at(face.normalized(), up)
	p.head.rotation.y = 0.0
	if MoonPlanet.instance != null:
		MoonPlanet.instance.ensure_above_ground(p, 0.05, 0.05)     # outside: never leave the player under the terrain
