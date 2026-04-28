class_name PlanetDef extends Resource

# Static definition of a planet entry in the planet pool. Runtime instances
# (with id, position, buildings) are GameState.PlanetData.

@export var planet_name: String = ""
@export var planet_type: String = "Rocky"  # "Rocky" | "Oceanic" | "Ice" | "Gas Giant"
