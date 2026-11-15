extends WorldSite
## The crafter: the only place repairs can be crafted. E on it (or standing within interact_radius of its
## origin) opens the crafter window, which lists the repairs and what they cost. The plain inventory window
## (I / Tab) shows materials only. While the crafter window is open Repairs.crafter_open is true; see
## InventoryUI.open_crafter().
##
## Mesh it by replacing PlaceholderMesh in crafter.tscn with your model. Keep the root script, and keep (or
## resize) the StaticBody3D so the crafter is solid and can be pointed at.


func _init() -> void:
	label = "crafter"
	interact_radius = 4.0


func _ready() -> void:
	super._ready()
	add_to_group("crafter")          # the crafter lives inside the base, so other code finds it by group, not by path


func prompt_text() -> String:
	return "Use the crafter"


func interact(_player: Node) -> void:
	InventoryUI.open_crafter()
