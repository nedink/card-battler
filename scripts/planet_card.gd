class_name PlanetCard extends Node2D

# A draggable card that represents one settled planet on the play space.
# Shares the player-card footprint (120×168). Buildings stack solitaire-style
# ABOVE the planet at full size, with the planet card forming the visual
# bottom of one clean column — each newer building is added one step further
# up and rendered behind the older ones, so older cards (and the planet body
# itself) cover all but the top peek of the cards above them.

signal planet_clicked(planet)

const SIZE := Vector2(120, 168)
const BODY_HALF := SIZE * 0.5
const SETTLE_SCALE_FROM := Vector2(0.3, 0.3)
const SETTLE_SCALE_TO := Vector2.ONE
const SETTLE_DURATION := 0.3

const NORMAL_BG := Color(0.18, 0.22, 0.32)
const NORMAL_BORDER := Color(0.4, 0.45, 0.55)
const TARGETED_BORDER := Color(1.0, 0.85, 0.2)
const SELECTED_BORDER := Color(0.45, 1.0, 0.55)
const BORDER_WIDTH_NORMAL := 3
const BORDER_WIDTH_HIGHLIGHT := 5

# Stacking config for attached building cards. The played card is reparented
# under _buildings_root and centred horizontally on the planet at full
# scale. Each new card sits BUILDING_STEP px above the previous, so only
# the top peek (name/cost row) of each card above the planet is visible —
# solitaire-style, with the planet body itself acting as the bottom card.
const BUILDING_CARD_SCALE := Vector2.ONE
const BUILDING_STEP := 28.0

@onready var _body: Panel = $Body
@onready var _name_label: Label = $Body/NameLabel
@onready var _type_label: Label = $Body/TypeLabel
@onready var _buildings_root: Node2D = $Buildings
@onready var _click_area: Area2D = $ClickArea

var data = null                       # GameState.PlanetData (typed Variant — autoload class)
var targeted: bool = false
var selected: bool = false
var draggable_in_bounds: bool = true

# Visual cards corresponding 1:1 to data.buildings entries. Owned by this
# planet card (children of _buildings_root). Kept in sync via attach + remove.
var _building_visuals: Array = []

# In-play bounds for manual reposition. Tightened on the top so a
# fully-built planet's solitaire card stack (which now grows upward) stays
# on screen, and on the bottom so the planet body stays clear of the hand
# at y≈580.
const PLAY_BOUNDS := Rect2(80, 220, 1120, 260)

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _body_stylebox: StyleBoxFlat = null

func _ready() -> void:
	_body_stylebox = (_body.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
	_body.add_theme_stylebox_override("panel", _body_stylebox)
	_click_area.input_event.connect(_on_input_event)
	# Buildings render behind the planet body so the planet is always the
	# bottom card of the visual stack. Inter-building order is set per-card
	# by attach_building_card so older cards cover newer ones — newest sits
	# at the very back.
	_buildings_root.z_index = -1
	_refresh_visual()
	if data != null:
		refresh_from_data()

func bind_data(p_data) -> void:
	data = p_data
	if is_node_ready():
		refresh_from_data()

func refresh_from_data() -> void:
	# Only the planet's own labels are managed from data here. Building
	# visuals are owned by attach/remove methods so they survive across
	# refreshes (they aren't rebuilt from data each time).
	if data == null:
		return
	if _name_label != null:
		_name_label.text = data.planet_name
	if _type_label != null:
		_type_label.text = data.planet_type

func attach_building_card(card: Card) -> void:
	# Take ownership of `card` as a permanent building visual. The card was
	# previously a child of Hand; reparent (preserving global transform) and
	# tween into the next slot. data.buildings has already been appended by
	# the caller, so the new visual's index matches the new data index.
	if card == null:
		return
	# reparent() preserves global transform so the visual doesn't jump.
	card.reparent(_buildings_root)
	_building_visuals.append(card)
	var index := _building_visuals.size() - 1
	card.settle_into_building_slot(_building_slot_local(index), BUILDING_CARD_SCALE)
	# Older cards (lower index) sit in front; the newest card lands at the
	# back. settle_into_building_slot resets z_index to 0, so set after.
	card.z_index = -index

func remove_building_visual_at(index: int) -> void:
	# Free the visual at `index` and re-tween any cards beneath it upward to
	# fill the gap. Caller is responsible for keeping data.buildings in sync.
	if index < 0 or index >= _building_visuals.size():
		return
	var v = _building_visuals[index]
	_building_visuals.remove_at(index)
	if is_instance_valid(v):
		v.queue_free()
	for i in range(_building_visuals.size()):
		var c: Card = _building_visuals[i]
		if is_instance_valid(c):
			c.settle_into_building_slot(_building_slot_local(i), BUILDING_CARD_SCALE)
			c.z_index = -i

func _building_slot_local(index: int) -> Vector2:
	# Local position (in _buildings_root coords) where the card centred at
	# slot `index` should sit. Buildings stack ABOVE the planet: each card's
	# top is BUILDING_STEP px above the previous card's top. Card 0 sits so
	# its top is BUILDING_STEP above the planet body's top edge, leaving a
	# clean STEP-tall peek for every card above the planet.
	var top_y := -BODY_HALF.y - float(index + 1) * BUILDING_STEP
	return Vector2(0.0, top_y + Card.SIZE.y * 0.5)

func set_targeted(value: bool) -> void:
	if targeted == value:
		return
	targeted = value
	_refresh_visual()

func set_selected(value: bool) -> void:
	if selected == value:
		return
	selected = value
	_refresh_visual()

func _refresh_visual() -> void:
	if _body_stylebox == null:
		return
	if selected:
		_body_stylebox.border_color = SELECTED_BORDER
		_set_border_width(BORDER_WIDTH_HIGHLIGHT)
	elif targeted:
		_body_stylebox.border_color = TARGETED_BORDER
		_set_border_width(BORDER_WIDTH_HIGHLIGHT)
	else:
		_body_stylebox.border_color = NORMAL_BORDER
		_set_border_width(BORDER_WIDTH_NORMAL)

func _set_border_width(w: int) -> void:
	_body_stylebox.border_width_left = w
	_body_stylebox.border_width_top = w
	_body_stylebox.border_width_right = w
	_body_stylebox.border_width_bottom = w

func play_settle_in() -> void:
	scale = SETTLE_SCALE_FROM
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "scale", SETTLE_SCALE_TO, SETTLE_DURATION)

func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton):
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		# Two interpretations: a click for trade-route selection (handled by
		# emitting the signal up the chain), and the start of a drag-to-move.
		# Listeners decide based on game phase.
		planet_clicked.emit(self)
		if draggable_in_bounds:
			_dragging = true
			_drag_offset = global_position - get_global_mouse_position()
	else:
		_dragging = false

func _process(_delta: float) -> void:
	if _dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_dragging = false
			return
		var target := get_global_mouse_position() + _drag_offset
		target.x = clampf(target.x, PLAY_BOUNDS.position.x, PLAY_BOUNDS.position.x + PLAY_BOUNDS.size.x)
		target.y = clampf(target.y, PLAY_BOUNDS.position.y, PLAY_BOUNDS.position.y + PLAY_BOUNDS.size.y)
		global_position = target
		if data != null:
			data.position = target

func contains_point(world_point: Vector2) -> bool:
	# Hit test for "card under cursor" while dragging a player card. Only the
	# body counts — clicks that land on the card stack below don't target the
	# planet for build placement.
	var local := to_local(world_point)
	var rect := Rect2(-BODY_HALF, SIZE)
	return rect.has_point(local)
