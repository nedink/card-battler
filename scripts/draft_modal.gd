class_name DraftModal extends CanvasLayer

# Full-screen modal that presents a small pack of cards and lets the player
# click one. Lifecycle is driven by the Draft autoload — present()/hide() are
# called from there.
#
# Each card in the pack is rendered using the same Card scene used in-hand
# (so the visuals match), but with its internal Control input ignored — clicks
# are caught by a transparent slot Control behind each card. The Backdrop's
# MOUSE_FILTER_STOP captures all mouse events behind the modal so neither the
# hand nor the play space process hover/click while a draft is up.

signal picked(chosen: CardData)

const CARD_SCENE: PackedScene = preload("res://scenes/card.tscn")

const CARD_SCALE := 1.3
const SLOT_SPACING := 32.0
const FADE_DURATION := 0.18
const ARC_FADE_DURATION := 0.22

@onready var _root: Control = $Root
@onready var _backdrop: ColorRect = $Root/Backdrop
@onready var _title: Label = $Root/Title
@onready var _slots: Control = $Root/Slots

var _cards: Array = []                     # Array[Card]
var _slot_controls: Array = []             # Array[Control] — clickable per-card
var _hovered_index: int = -1
var _arc_target_world: Vector2 = Draft.NO_ARC_TARGET

func _ready() -> void:
	_root.visible = false
	_root.modulate.a = 0.0

func present(pack: Array, arc_target_world: Vector2 = Draft.NO_ARC_TARGET) -> void:
	_clear()
	_arc_target_world = arc_target_world
	if pack.is_empty():
		# Edge case — degenerate pack. Bail without showing anything.
		picked.emit(null)
		return
	var slot_w := Card.SIZE.x * CARD_SCALE
	var slot_h := Card.SIZE.y * CARD_SCALE
	var n := pack.size()
	var total_w := float(n) * slot_w + float(n - 1) * SLOT_SPACING
	var viewport := _root.size
	var x_origin := (viewport.x - total_w) * 0.5
	var y_origin := (viewport.y - slot_h) * 0.5
	for i in range(n):
		var def: CardData = pack[i]
		var slot := Control.new()
		slot.size = Vector2(slot_w, slot_h)
		slot.position = Vector2(x_origin + float(i) * (slot_w + SLOT_SPACING), y_origin)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		_slots.add_child(slot)
		slot.gui_input.connect(_on_slot_input.bind(i))
		slot.mouse_entered.connect(_on_slot_mouse_entered.bind(i))
		slot.mouse_exited.connect(_on_slot_mouse_exited.bind(i))
		_slot_controls.append(slot)

		var card: Card = CARD_SCENE.instantiate()
		slot.add_child(card)
		card.configure(def)
		# Centre the card within its slot. Card draws around its own origin.
		# Card._process lerps toward rest_position when IDLE, so we have to
		# set rest to the same point or the card drifts to the slot's origin.
		var card_pos := slot.size * 0.5
		card.position = card_pos
		card.scale = Vector2(CARD_SCALE, CARD_SCALE)
		card.set_rest(card_pos, 0.0)
		# Clicks are caught by the slot — let them pass through the card visuals.
		Card.disable_input_subtree(card)
		_cards.append(card)

	_hovered_index = -1
	_root.visible = true
	var tween := create_tween()
	tween.tween_property(_root, "modulate:a", 1.0, FADE_DURATION)

func _on_slot_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_resolve(index)

func _on_slot_mouse_entered(index: int) -> void:
	_set_hovered(index)

func _on_slot_mouse_exited(index: int) -> void:
	if _hovered_index == index:
		_set_hovered(-1)

func _set_hovered(index: int) -> void:
	if _hovered_index == index:
		return
	if _hovered_index >= 0 and _hovered_index < _cards.size():
		var prev: Card = _cards[_hovered_index]
		if is_instance_valid(prev):
			prev.set_hovered(false)
	_hovered_index = index
	if index >= 0 and index < _cards.size():
		var cur: Card = _cards[index]
		if is_instance_valid(cur):
			cur.set_hovered(true)

func _resolve(index: int) -> void:
	if index < 0 or index >= _cards.size():
		return
	var chosen_card: Card = _cards[index]
	var chosen_data: CardData = chosen_card.data
	# Disable further input while we resolve.
	for slot in _slot_controls:
		(slot as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	chosen_card.set_hovered(false)
	_hovered_index = -1

	if _arc_target_world == Draft.NO_ARC_TARGET:
		# No arc target supplied — original behaviour: fade everything out.
		var tween := create_tween()
		tween.tween_property(_root, "modulate:a", 0.0, FADE_DURATION)
		tween.tween_callback(func() -> void:
			_root.visible = false
			_clear()
			picked.emit(chosen_data))
		return

	# Arc the chosen card toward the destination deck while everything else
	# fades. The card's discard_fly handles the bezier + spin + shrink in its
	# own (parent-local) frame; world target is converted by the card itself.
	for i in range(_cards.size()):
		if i == index:
			continue
		var c: Card = _cards[i]
		var fade_tween := create_tween()
		fade_tween.tween_property(c, "modulate:a", 0.0, ARC_FADE_DURATION)
	var bg_tween := create_tween()
	bg_tween.tween_property(_backdrop, "modulate:a", 0.0, ARC_FADE_DURATION)
	bg_tween.parallel().tween_property(_title, "modulate:a", 0.0, ARC_FADE_DURATION)

	chosen_card.fly_finished.connect(_on_chosen_arc_done.bind(chosen_data), CONNECT_ONE_SHOT)
	chosen_card.discard_fly(_arc_target_world)

func _on_chosen_arc_done(_card: Card, chosen_data: CardData) -> void:
	_root.visible = false
	_root.modulate.a = 0.0
	_backdrop.modulate.a = 1.0
	_title.modulate.a = 1.0
	_clear()
	picked.emit(chosen_data)

func _clear() -> void:
	for c in _slots.get_children():
		c.queue_free()
	_cards.clear()
	_slot_controls.clear()
	_hovered_index = -1
