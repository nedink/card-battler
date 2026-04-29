@tool
class_name Hand extends Node2D

# target_planet is null for non-targeted cards (Discover, Trade Route).
signal card_played(card: Card, target_planet)

@export var max_card_spacing: float = 110.0:
	set(value):
		max_card_spacing = value
		queue_redraw()

# Hand-local y; release above (less than) this triggers a play.
@export var play_threshold_y: float = -90.0:
	set(value):
		play_threshold_y = value
		queue_redraw()

# Editor-only: width of the threshold line drawn for visualization.
@export var editor_threshold_width: float = 700.0:
	set(value):
		editor_threshold_width = value
		queue_redraw()

@onready var path: Path2D = $Path2D

# Stacking ranks. Cards in hand take HAND_Z_BASE .. HAND_Z_BASE+n-1
# (left-to-right). Hover and drag boost a card above the fan; flying retains
# the drag boost so the card stays on top of everything until queue_free.
# HAND_Z_BASE is set above 0 so freshly-drawn cards always render above any
# end-turn-discarded cards still arcing toward the discard pile (those reset
# to z=0 in Card.discard_fly).
const HAND_Z_BASE := 10
const HOVER_Z := 100
const DRAG_Z := 1000

var cards: Array[Card] = []
var _hovered_card: Card = null
var _dragging_card: Card = null
# Optional Callable(card: Card) -> bool. When set, used to gate plays — a card
# only counts as play-ready if this returns true. Lets Hand stay decoupled from
# whatever play-gating the game wants (e.g. trade-route mode disables all plays).
var can_play_card: Callable = Callable()

# Reference to the play space — set by main.gd after both nodes exist. While a
# planet-targeting card is being dragged, the hand asks the play space for the
# planet under the cursor and toggles its highlight.
var play_space: Node = null
var _last_targeted_planet: Node = null

# Set true by main.gd while a modal overlay is up (e.g. the pile viewer). When
# paused, the hand drops any active hover and skips hover/drag tracking so
# cards don't lift in response to mouse movement under the modal.
var input_paused: bool = false

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if input_paused:
		# Modal up — drop hover so the lifted card doesn't sit elevated under
		# the overlay, and don't bother updating hover/drag this frame.
		if _hovered_card != null:
			clear_hover()
		return
	if _dragging_card != null:
		var mouse := get_global_mouse_position()
		_dragging_card.update_drag_position(mouse)
		if _dragging_card.targets_planet:
			# Planet-targeting cards: highlight the planet under the cursor when
			# the card is playable; release-to-play lights up only while a target
			# is hovered.
			var hit = null
			if play_space != null and _is_card_playable(_dragging_card) and play_space.has_method("get_planet_under_cursor"):
				hit = play_space.get_planet_under_cursor(mouse)
			_set_targeted_planet(hit)
			_dragging_card.set_play_ready(hit != null)
		else:
			_set_targeted_planet(null)
			# Live feedback: green = release-to-play, neutral = release-returns-to-hand.
			# The whole card must clear the threshold AND be playable.
			_dragging_card.set_play_ready(_card_clears_threshold(_dragging_card) and _is_card_playable(_dragging_card))
	else:
		_update_hover()

func _set_targeted_planet(planet) -> void:
	if planet == _last_targeted_planet:
		return
	if _last_targeted_planet != null and is_instance_valid(_last_targeted_planet) \
			and _last_targeted_planet.has_method("set_targeted"):
		_last_targeted_planet.set_targeted(false)
	_last_targeted_planet = planet
	if planet != null and planet.has_method("set_targeted"):
		planet.set_targeted(true)

func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if _dragging_card == null and _hovered_card != null:
				_start_drag(_hovered_card)
				get_viewport().set_input_as_handled()
		else:
			if _dragging_card != null:
				_end_drag()
				get_viewport().set_input_as_handled()

func _draw() -> void:
	# Visualize the play threshold in the editor so you can see where
	# "release-to-play" kicks in relative to the hand origin.
	if not Engine.is_editor_hint():
		return
	var half := editor_threshold_width * 0.5
	var color := Color(1.0, 0.85, 0.3, 0.55)
	draw_line(Vector2(-half, play_threshold_y), Vector2(half, play_threshold_y), color, 2.0)
	# Tick marks at the ends.
	draw_line(Vector2(-half, play_threshold_y - 8), Vector2(-half, play_threshold_y + 8), color, 2.0)
	draw_line(Vector2(half, play_threshold_y - 8), Vector2(half, play_threshold_y + 8), color, 2.0)
	# Origin crosshair.
	var origin_color := Color(0.5, 1.0, 0.7, 0.5)
	draw_line(Vector2(-10, 0), Vector2(10, 0), origin_color, 1.0)
	draw_line(Vector2(0, -10), Vector2(0, 10), origin_color, 1.0)

func add_card(card: Card, spawn_world: Vector2) -> void:
	add_child(card)
	card.position = to_local(spawn_world)
	cards.append(card)
	layout()

func is_dragging() -> bool:
	return _dragging_card != null

func has_hovered_card() -> bool:
	return _hovered_card != null

func clear_hover() -> void:
	# Force-unhover whatever's currently hovered. Used at end-of-turn before
	# the hand is wiped, so the hovered card doesn't fly off to the discard
	# pile with its elevated HOVER_Z still applied (which would put it above
	# the freshly-drawn cards).
	if _hovered_card == null:
		return
	_hovered_card.set_hovered(false)
	var idx := cards.find(_hovered_card)
	_hovered_card.z_index = HAND_Z_BASE + idx if idx >= 0 else 0
	_hovered_card = null

func _start_drag(card: Card) -> void:
	_dragging_card = card
	_hovered_card = null
	card.set_hovered(false)
	card.start_drag()
	card.z_index = DRAG_Z
	# Re-layout the remaining cards so the gap closes immediately.
	layout()

func _end_drag() -> void:
	var card := _dragging_card
	_dragging_card = null
	if card.targets_planet:
		# Drag-onto-planet: only plays if a planet is currently targeted AND the
		# card is otherwise playable. Threshold doesn't apply — the player
		# might drop directly on a planet without raising the card high.
		var target = _last_targeted_planet
		_set_targeted_planet(null)
		if target != null and _is_card_playable(card):
			cards.erase(card)
			layout()
			card_played.emit(card, target)
		else:
			card.end_drag_return()
			layout()
	elif _card_clears_threshold(card) and _is_card_playable(card):
		# Released outside the hand zone with a playable card: remove and fly off.
		cards.erase(card)
		layout()
		card_played.emit(card, null)
	else:
		# Released inside the hand zone OR not playable: it slots back in.
		card.end_drag_return()
		layout()

func _card_clears_threshold(card: Card) -> bool:
	# True only when the card's bottom edge is strictly above the threshold line.
	# Using card.position (= cursor in hand-local during drag) keeps this in sync
	# with what the player sees.
	return card.position.y + Card.SIZE.y * 0.5 < play_threshold_y

func _is_card_playable(card: Card) -> bool:
	if not can_play_card.is_valid():
		return true
	return bool(can_play_card.call(card))

func layout() -> void:
	if path == null or path.curve == null:
		return
	var n := 0
	for c in cards:
		if c != _dragging_card:
			n += 1
	if n == 0:
		return
	var curve := path.curve
	var length := curve.get_baked_length()
	var spacing: float = min(max_card_spacing, length / float(max(n, 1)))
	var total: float = spacing * float(n - 1)
	var start_offset: float = (length - total) * 0.5
	var i := 0
	for c in cards:
		if c == _dragging_card:
			continue
		var offset: float = (length * 0.5) if n == 1 else start_offset + spacing * float(i)
		var xform := curve.sample_baked_with_rotation(offset, true)
		c.set_rest(xform.get_origin(), xform.get_rotation())
		# Fan position drives z-order: rightmost card renders above its left neighbor.
		# Don't clobber the hovered card's elevated z here.
		if c != _hovered_card:
			c.z_index = HAND_Z_BASE + i
		i += 1

func _update_hover() -> void:
	var mouse := get_global_mouse_position()
	var found: Card = null
	# Sticky-test the current hovered card first so cards in an overlap
	# region don't flicker between each other when the cursor sits between
	# them — once you're on a card, you stay on it until you exit its rect.
	if _hovered_card != null and _hovered_card in cards and _point_in_card(_hovered_card, mouse):
		found = _hovered_card
	else:
		# Otherwise pick the right-most card under the cursor (highest fan
		# index = highest z, so it renders on top in the overlap stack).
		for j in range(cards.size() - 1, -1, -1):
			var c := cards[j]
			if c == _dragging_card:
				continue
			if _point_in_card(c, mouse):
				found = c
				break
	if found == _hovered_card:
		return
	if _hovered_card != null:
		_hovered_card.set_hovered(false)
		# Restore the natural fan z-order on the previously-hovered card.
		# If it's no longer in the hand (e.g. removed during end-turn), drop
		# it to z=0 so it doesn't render above newly-drawn cards.
		var idx := cards.find(_hovered_card)
		_hovered_card.z_index = HAND_Z_BASE + idx if idx >= 0 else 0
	_hovered_card = found
	if found != null:
		found.set_hovered(true)
		found.z_index = HOVER_Z

func _point_in_card(card: Card, world_point: Vector2) -> bool:
	# Hit-test against the rest pose, expanded upward to cover the hover lift.
	var hand_local := to_local(world_point)
	var rest_xform := Transform2D(card.rest_rotation, card.rest_position)
	var card_local := rest_xform.affine_inverse() * hand_local
	var rect := Rect2(
		Vector2(-Card.SIZE.x * 0.5, -Card.SIZE.y * 0.5 - Card.HOVER_LIFT),
		Vector2(Card.SIZE.x, Card.SIZE.y + Card.HOVER_LIFT))
	return rect.has_point(card_local)
