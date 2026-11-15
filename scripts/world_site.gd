extends Node3D
class_name WorldSite
## Put this script on the root of any scene the player can interact with with E. The base class is a salvage
## site; scripts that extend it (crafter.gd, rover1.gd) change what E does by overriding two functions.
##
##   Salvage  (salvage = true)   E gives the loot Repairs.LOOT[salvage_id] once, and the source is then marked
##                               as picked clean in the save. salvage_id empty = this node's name (GameState
##                               names placed objects "InteriorBase", "Rover1_1", ...).
##
## The player interacts by pointing at one of its colliders (any collider below this node works), or, if there
## is none, by standing within interact_radius of its origin. Scenes without collision shapes still work.

@export var label := "Site"
@export var interact_radius := 4.0

@export_group("Salvage")
@export var salvage := false
@export var salvage_id := ""


func _ready() -> void:
	add_to_group("interactible")


func _salvage_key() -> String:
	return salvage_id if salvage_id != "" else str(name)


## What the HUD shows after "E:".
func prompt_text() -> String:
	if salvage and not Repairs.is_salvaged(_salvage_key()):
		return "Salvage %s" % label
	return "%s: picked clean" % label


## Called by the player when E is pressed on this site.
func interact(_player: Node) -> void:
	Repairs.salvage(_salvage_key())              # gives the loot, or says there is nothing left
