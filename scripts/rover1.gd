extends WorldSite
## A rover1 wreck: a salvage site. The loot comes from Repairs.LOOT, keyed by this node's name
## (GameState names the placed rovers "Rover1_1" .. "Rover1_3").


func _init() -> void:
	label = "rover wreck"
	salvage = true
	interact_radius = 6.0
