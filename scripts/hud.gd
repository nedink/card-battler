class_name Hud extends Node2D

# Top-bar resource + turn display. Subscribes to GameState.resources_changed
# and refreshes itself; main.gd just calls set_turn() when the turn advances.

@onready var _credits: Label = $Bar/Credits
@onready var _research: Label = $Bar/Research
@onready var _energy: Label = $Bar/Energy
@onready var _turn: Label = $Bar/Turn

func _ready() -> void:
	GameState.resources_changed.connect(refresh)
	refresh()

func refresh() -> void:
	if _credits == null:
		return
	_credits.text = "Credits: %d" % GameState.credits
	_research.text = "Research: %d" % GameState.research
	_energy.text = "Energy: %d" % GameState.energy
	_turn.text = "Turn: %d" % GameState.turn_number

func set_turn(_n: int) -> void:
	# Kept for explicit calls from main.gd; refresh reads GameState directly.
	refresh()
