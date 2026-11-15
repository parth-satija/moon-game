extends WorldSite
## A door of the lunar base (see interior_base.gd). Put it on a Node3D that is a direct child of the base's root.
## entering = true is the outside airlock ("Enter the base"), false is the inner hatch ("Exit the base").
##
## Give it a StaticBody3D child (the airlock module, the hatch) so the player can point at it; the interact
## ray walks up from whatever it hits to this node. Without one it still works by standing within
## interact_radius of it.

@export var entering := true


func _init() -> void:
	label = "base door"
	interact_radius = 3.5


func prompt_text() -> String:
	return "Enter the base" if entering else "Exit the base"


func interact(player: Node) -> void:
	var base := get_parent()
	if base != null and base.has_method("enter"):
		base.call("enter" if entering else "leave", player)
