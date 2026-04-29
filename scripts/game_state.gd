extends Node

# Central game state singleton (autoload as `GameState`).
#
# Holds persistent world state: planets, decks, turn counter. Scenes mutate
# this directly and emit signals so the play space can refresh without owning
# its own copies.

# ---------------------------------------------------------------------------
# Inner data classes

class PlanetData:
	var id: int
	var planet_name: String
	var planet_type: String          # "Rocky" | "Oceanic" | "Ice" | "Gas Giant"
	var card_types: Array            # Tags for stack-matching — see CardData.card_types
	var buildings: Array              # Array[BuildingData], stacked atop the planet
	var position: Vector2

	func _init(p_id: int = 0, p_name: String = "", p_type: String = "", p_pos: Vector2 = Vector2.ZERO, p_card_types: Array = []) -> void:
		id = p_id
		planet_name = p_name
		planet_type = p_type
		position = p_pos
		card_types = p_card_types.duplicate()
		buildings = []

class BuildingData:
	# A card that has been stacked onto a planet. `source` is the CardData the
	# played card was instantiated from — kept around so we can rebuild the
	# pile/visual representation and so other systems can read the source's
	# tags and effects.
	var source: CardData
	var card_types: Array            # Snapshot of source.card_types — what the next stacker tests against

	func _init(p_source: CardData = null) -> void:
		source = p_source
		card_types = p_source.card_types.duplicate() if p_source != null else []

# ---------------------------------------------------------------------------
# Signals

signal planet_settled(data)
signal turn_phase_changed(phase: int)

# ---------------------------------------------------------------------------
# World state

var planets: Array = []                # Array[PlanetData]
# Card stores hold CardData refs. The visual for each is rebuilt at draw time
# via Card.configure(data).
var player_deck: Array = []            # Array[CardData] — waiting to be drawn
var player_discard: Array = []         # Array[CardData] — recycle into the deck
var player_exile: Array = []           # Array[CardData] — removed for the run
var planet_deck_data: Array = []       # Array[PlanetData] — face-down pool
var turn_number: int = 1
var total_buildings_placed: int = 0

# ---------------------------------------------------------------------------
# Helpers

func find_planet_by_id(planet_id: int):
	for p in planets:
		if p.id == planet_id:
			return p
	return null

func building_count() -> int:
	var n := 0
	for p in planets:
		n += p.buildings.size()
	return n
