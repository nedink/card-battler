class_name Deck extends Node2D

# Generic pile-with-count node, used for both the player draw deck and the
# planet deck. Emits `pile_clicked` on left-click so the player can pop open
# a viewer of its contents (handled by main.gd).

signal pile_clicked

@onready var _count_label: Label = $Body/CountLabel
@onready var _click_area: Area2D = $ClickArea

var cards_remaining: int = 20:
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
