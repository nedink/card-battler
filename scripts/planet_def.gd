class_name PlanetDef extends Resource

# Static definition of a planet entry in the planet pool. Runtime instances
# (with id, position, buildings) are GameState.PlanetData.

@export var planet_name: String = ""
@export var planet_type: String = "Rocky"  # "Rocky" | "Oceanic" | "Ice" | "Gas Giant"

# Tags participating in the card stacking system — see CardData.card_types.
# Defaults to ["planet"] so any card whose can_stack includes "planet" can be
# played onto a fresh planet.
@export var card_types: Array[String] = ["planet"]
