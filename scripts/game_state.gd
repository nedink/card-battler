extends Node

# Central game state singleton (autoload as `GameState`).
#
# Holds persistent run state — decks, turn counter, run-wide counters. The
# board state itself (which stacks live in which cells, what's stacked under
# what) lives in the play_space scene tree, not here. Walk play_space when
# you need to query the board.

# ---------------------------------------------------------------------------
# Signals

signal turn_phase_changed(phase: int)

# ---------------------------------------------------------------------------
# Run state

# Player card stores hold CardData refs. The visual for each is rebuilt at draw
# time via Card.configure(data).
var player_deck: Array = []            # Array[CardData] — waiting to be drawn
var player_discard: Array = []         # Array[CardData] — recycle into the deck
var player_exile: Array = []           # Array[CardData] — removed for the run

# Discovery deck — face-down pool of CardData, popped one per turn. Per-card
# tags decide where the entry settles on the board.
var planet_deck_data: Array = []       # Array[CardData]

var turn_number: int = 1
var total_buildings_placed: int = 0
