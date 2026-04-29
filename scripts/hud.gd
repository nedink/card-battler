class_name Hud extends Node2D

# Top-bar turn display. main.gd calls set_turn() when the turn advances.

@onready var _turn: Label = $Bar/Turn

func _ready() -> void:
	refresh()

func refresh() -> void:
	if _turn == null:
		return
	_turn.text = "Turn: %d" % GameState.turn_number

func set_turn(_n: int) -> void:
	refresh()
