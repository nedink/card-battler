extends Node

# Central game state singleton (autoload as `GameState`).
#
# Holds all persistent gameplay data: resources, planets, trade routes, decks,
# event flags, turn counter. Scenes mutate this directly and emit signals so the
# HUD and play space can refresh without owning their own copies of the data.

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
	var blocked: bool = false        # Solar Flare event sets this for one turn

	func _init(a_id: int = -1, b_id: int = -1) -> void:
		planet_a_id = a_id
		planet_b_id = b_id

# ---------------------------------------------------------------------------
# Constants

const BUILDING_DEFS := {
	"Colony":       { "credits": 1, "research": 0, "energy": 0 },
	"Factory":      { "credits": 2, "research": 0, "energy": -1 },
	"Lab":          { "credits": 0, "research": 1, "energy": 0 },
	"Power Plant":  { "credits": 0, "research": 0, "energy": 2 }
}

const MAX_BUILDINGS_PER_PLANET := 4

# ---------------------------------------------------------------------------
# Signals

signal resources_changed
signal planet_settled(data)
signal turn_phase_changed(phase: int)
signal game_over_triggered(score: int)

# ---------------------------------------------------------------------------
# Resource state

var credits: int = 0:
	set(value):
		credits = maxi(0, value)
		resources_changed.emit()
var research: int = 0:
	set(value):
		research = maxi(0, value)
		resources_changed.emit()
var energy: int = 0:
	set(value):
		energy = maxi(0, value)
		resources_changed.emit()

# ---------------------------------------------------------------------------
# World state

var planets: Array = []                # Array[PlanetData]
var trade_routes: Array = []           # Array[TradeRouteData]
# Card stores hold card_type enum values (ints) — the visual + cost for each
# is rebuilt from main.gd's CARD_LIBRARY (data/card_library.tres) at draw time.
var player_deck: Array = []            # Cards waiting to be drawn
var player_discard: Array = []         # Cards played that recycle into the deck
var player_exile: Array = []           # Cards played that are removed from the game (Discover)
var planet_deck_data: Array = []       # Array[PlanetData] — face-down pool
var event_deck: Array = []             # Array[Dictionary]
var turn_number: int = 1
var total_buildings_placed: int = 0

# Per-turn event flags. Cleared at the start of INCOME each turn.
var credits_halved_this_turn: bool = false
var trade_routes_blocked_this_turn: bool = false
var plagued_planet_id: int = -1

# ---------------------------------------------------------------------------
# Helpers

func can_afford(cost: Dictionary) -> bool:
	# cost: { "credits": N, "research": N, "energy": N } — any field optional.
	return credits >= int(cost.get("credits", 0)) \
		and research >= int(cost.get("research", 0)) \
		and energy >= int(cost.get("energy", 0))

func deduct(cost: Dictionary) -> void:
	credits -= int(cost.get("credits", 0))
	research -= int(cost.get("research", 0))
	energy -= int(cost.get("energy", 0))

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

func reset_per_turn_flags() -> void:
	credits_halved_this_turn = false
	trade_routes_blocked_this_turn = false
	plagued_planet_id = -1
	for route in trade_routes:
		route.blocked = false
