class_name ExilePile extends Node2D

# Counter + click area for the exile pile. Cards put into exile are removed
# from the game for the rest of the run — the player can still pop the viewer
# to see what's been exiled.

signal pile_clicked

@onready var _count_label: Label = $Body/CountLabel
@onready var _click_area: Area2D = $ClickArea

var cards_remaining: int = 0:
	set(value):
		cards_remaining = value
		if is_node_ready():
			_count_label.text = str(value)

func _ready() -> void:
	_count_label.text = str(cards_remaining)
	_click_area.input_event.connect(_on_input_event)

func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pile_clicked.emit()
