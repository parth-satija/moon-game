extends Node
## Wires the Player to the MoonPlanet, which is expected to be the ROOT of the scene the Player is
## instanced into (main.tscn's root node running moon.gd).
##
## Runs in _enter_tree, which happens for every node before any _ready, so the planet already knows
## its player when it builds the first mesh and places the spawn point.

func _enter_tree() -> void:
	var player := get_parent() as MoonPlayer
	if player == null:
		return

	# The root of the scene this player was instanced into.
	var root: Node = player.owner
	if root == null:
		root = get_tree().current_scene
	if root == null:
		root = player.get_parent()

	var moon := root as MoonPlanet
	if moon == null:
		moon = _search(root)          # fallback: root isn't a MoonPlanet, look below it
	if moon == null:
		push_warning("MoonPlayer: the scene root '%s' is not a MoonPlanet (moon.gd), so the player can't walk on the moon." % root.name)
		return

	player.moon = moon
	moon.player = player


func _search(node: Node) -> MoonPlanet:
	if node is MoonPlanet:
		return node
	for c in node.get_children():
		var r := _search(c)
		if r != null:
			return r
	return null
