class_name Deck extends Node2D

# Generic pile-with-count node, used for both the player draw deck and the
# planet deck. Emits `pile_clicked` on left-click so the player can pop open
# a viewer of its contents (handled by main.gd).

signal pile_clicked

@onready var _body: Panel = $Body
@onready var _count_label: Label = $Body/CountLabel
@onready var _click_area: Area2D = $ClickArea

var cards_remaining: int = 20:
	set(value):
		cards_remaining = value
		if is_node_ready():
			_count_label.text = str(value)

var _hover_tween: Tween

func _ready() -> void:
	_count_label.text = str(cards_remaining)
	_click_area.input_event.connect(_on_input_event)
	_click_area.mouse_entered.connect(_on_mouse_entered)
	_click_area.mouse_exited.connect(_on_mouse_exited)

func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pile_clicked.emit()

func _on_mouse_entered() -> void:
	_animate_hover(true)

func _on_mouse_exited() -> void:
	_animate_hover(false)

func _animate_hover(hovered: bool) -> void:
	if _hover_tween and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel()
	var target_scale := Vector2(1.05, 1.05) if hovered else Vector2.ONE
	var target_mod := Color(1.25, 1.25, 1.25) if hovered else Color.WHITE
	_hover_tween.tween_property(self, "scale", target_scale, 0.1)
	_hover_tween.tween_property(_body, "modulate", target_mod, 0.1)
