extends Node
## Autoload "PlayerSwap": makes moon_planet.scn (a binary scene that cannot be edited as text) use the
## player_test.tscn setup. It watches for the MoonPlayer node entering the tree, and BEFORE its _ready runs it
## converts it in place: player_test.gd script, the same collision shape / margins / camera near plane that
## player_test.tscn defines. Converting in place (instead of replacing the node) keeps every reference to the
## player (moon.player, MoonPlanet's NodePath, GameState, LunarNav, vehicles) valid.
##
## To go back to the old player, set ENABLED to false (or remove this autoload from project.godot).
## Once you are happy with the result, bake the same settings into player.tscn and delete this file.

const ENABLED := true
const TEST_SCRIPT := "res://scripts/player_test.gd"
const TEST_SCENE := "res://scenes/player_test.tscn"


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not ENABLED or not (node is MoonPlayer) or node.get_script() == null:
		return
	if (node.get_script() as Script).resource_path == TEST_SCRIPT:
		return                                           # already the test player (player_test.tscn placed directly)
	var parent := node.get_parent()
	if parent == null or not (parent is MoonPlanet or parent.get_node_or_null("MoonPlanet") != null):
		return                                           # not the player of a moon scene
	var script := load(TEST_SCRIPT) as Script
	var template := load(TEST_SCENE) as PackedScene
	if script == null or template == null:
		push_warning("PlayerSwap: %s or %s is missing, keeping the original player" % [TEST_SCRIPT, TEST_SCENE])
		return

	# Read the values player_test.tscn sets (it is the single source of truth), from a throwaway instance.
	var ref := template.instantiate()
	var body := node as CharacterBody3D
	node.set_script(script)
	for prop in ["max_fall_speed", "guard_margin_m", "guard_clearance_m", "floor_margin_m"]:
		node.set(prop, ref.get(prop))
	body.safe_margin = (ref as CharacterBody3D).safe_margin

	var ref_shape := ref.get_node_or_null("CollisionShape3D") as CollisionShape3D
	var shape_node := node.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if ref_shape != null and shape_node != null and ref_shape.shape != null:
		shape_node.shape = ref_shape.shape.duplicate()
		shape_node.transform = ref_shape.transform
	var ref_cam := ref.get_node_or_null("Head/Camera3D") as Camera3D
	var cam := node.get_node_or_null("Head/Camera3D") as Camera3D
	if ref_cam != null and cam != null:
		cam.near = ref_cam.near
	ref.free()
	print("PlayerSwap: %s now uses the player_test setup" % node.name)
