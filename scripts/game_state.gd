extends Node

# Central game state singleton (autoload as `GameState`).
#
# Holds persistent world state: planets, trade routes, decks, turn counter.
# Scenes mutate this directly and emit signals so the play space can refresh
# without owning its own copies.

# ---------------------------------------------------------------------------
# Inner data classes

class PlanetData:
	var id: int
	var planet_name: String
	var planet_type: String          # "Rocky" | "Oceanic" | "Ice" | "Gas Giant"
	var buildings: Array              # Array[BuildingData], max 4
	var position: Vector2

	func _init(p_id: int = 0, p_name: String = "", p_type: String = "", p_pos: Vector2 = Vector2.ZERO) -> void:
		id = p_id
		planet_name = p_name
		planet_type = p_type
		position = p_pos
		buildings = []

class BuildingData:
	var building_type: String        # "Colony" | "Factory" | "Lab" | "Power Plant"

	func _init(p_type: String = "") -> void:
		building_type = p_type

class TradeRouteData:
	var planet_a_id: int
	var planet_b_id: int

	func _init(a_id: int = -1, b_id: int = -1) -> void:
		planet_a_id = a_id
		planet_b_id = b_id

# ---------------------------------------------------------------------------
# Constants

const MAX_BUILDINGS_PER_PLANET := 4

# ---------------------------------------------------------------------------
# Signals

signal planet_settled(data)
signal turn_phase_changed(phase: int)

# ---------------------------------------------------------------------------
# World state

var planets: Array = []                # Array[PlanetData]
var trade_routes: Array = []           # Array[TradeRouteData]
# Card stores hold card_type enum values (ints) — the visual for each is rebuilt
# from main.gd's CARD_LIBRARY (data/card_library.tres) at draw time.
var player_deck: Array = []            # Cards waiting to be drawn
var player_discard: Array = []         # Cards played that recycle into the deck
var player_exile: Array = []           # Cards played that are removed from the game (Discover)
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
