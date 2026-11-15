extends WorldSite
## The underside of the crashed Starship: the reserve salvage (Repairs.LOOT["wreck_underside"]).
##
## The hull lies pressed into the regolith, so this site stays closed until the lunar buggy has lifted it
## (lrv.gd: F at the crash site). Once it is open it is salvaged like any other source, once.
## LandingSite creates it under the hull and calls activate() when the lift finishes, or when the crash site
## is rebuilt in a slot where the hull was already lifted.

var _active := false
var _glow: OmniLight3D


func _init() -> void:
	label = "Starship underside"
	salvage = true
	salvage_id = "wreck_underside"
	interact_radius = 9.0


func _ready() -> void:
	# Deliberately not calling super: until the hull is lifted this must not join the "interactible" group,
	# or the player would be offered a salvage prompt under a hull that is lying on the ground.
	if LandingSite.is_wreck_lifted():
		activate()


func activate() -> void:
	if _active:
		return
	_active = true
	add_to_group("interactible")
	if _glow == null:
		_glow = OmniLight3D.new()
		_glow.light_color = Color(1.0, 0.6, 0.25)
		_glow.light_energy = 1.2
		_glow.omni_range = 7.0
		add_child(_glow)
