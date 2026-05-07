@tool
class_name Hand extends Node2D

# target_planet is null for threshold-released cards.
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

# Cards in hand take ZLayers.HAND_FAN_BASE .. + n-1 (left-to-right). Hover
# and drag elevate above the fan; the band layout in z_layers.gd documents
# how these stack against the board.

var cards: Array[Card] = []
var _hovered_card: Card = null
var _dragging_card: Card = null
# EMA of the dragging card's parent-local velocity. Sampled per-frame from
# card.position deltas while dragging, then handed off to the card on release
# so threshold-played cards drift in the direction of the final mouse motion.
var _drag_velocity: Vector2 = Vector2.ZERO
var _drag_last_pos: Vector2 = Vector2.ZERO
# Skip the first frame's sample — at drag start, card.position is the rest pose
# and snaps to the cursor on the next update, which would register as a huge
# spurious velocity.
var _drag_velocity_seeded: bool = false
# Per-second response of the velocity EMA. Higher = tracks recent motion more
# tightly (better for "what was the mouse doing at release?"); lower = smooths
# more across the full drag.
const DRAG_VELOCITY_RESPONSE := 25.0
# Optional Callable(card: Card) -> bool. When set, used to gate plays — a card
# only counts as play-ready if this returns true. Lets Hand stay decoupled from
# whatever play-gating the game wants (e.g. a future modal that disables plays).
var can_play_card: Callable = Callable()

# Reference to the play space — set by main.gd after both nodes exist. While a
# stack-targeting card is being dragged, the hand asks the play space for the
# stack under the cursor and toggles its highlight.
var play_space: Node = null
var _last_targeted_planet: Node = null

# Set by main.gd. Played once per new card-hover acquisition.
var hover_audio: AudioStreamPlayer2D = null

# Set true by main.gd while a modal overlay is up (e.g. the pile viewer). When
# paused, the hand drops any active hover and skips hover/drag tracking so
# cards don't lift in response to mouse movement under the modal.
var input_paused: bool = false

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if input_paused or _play_space_busy():
		# Either a modal is up or the play space is dragging a stack. Drop the
		# hover so a previously-lifted card doesn't sit elevated under the
		# overlay/drag, and skip per-frame interaction this frame.
		if _hovered_card != null:
			clear_hover()
		return
	if _dragging_card != null:
		var mouse := get_global_mouse_position()
		_dragging_card.update_drag_position(mouse)
		_sample_drag_velocity(delta)
		if _dragging_card.releases_on_threshold:
			_set_targeted_planet(null)
			# Live feedback: green = release-to-play, neutral = release-returns-to-hand.
			# The whole card must clear the threshold AND be playable.
			_dragging_card.set_play_ready(_card_clears_threshold(_dragging_card) and _is_card_playable(_dragging_card))
		else:
			# Stack-targeting cards: highlight a stack whose top satisfies the
			# card's can_stack tags. release-to-play lights up only while a
			# valid target is hovered.
			var hit = _find_stack_target(mouse, _dragging_card)
			_set_targeted_planet(hit)
			_dragging_card.set_play_ready(hit != null)
	else:
		_update_hover()

func _find_stack_target(mouse: Vector2, card: Card):
	if play_space == null or not _is_card_playable(card):
		return null
	if not play_space.has_method("get_planet_under_cursor"):
		return null
	var hit = play_space.get_planet_under_cursor(mouse)
	if hit == null:
		return null
	if hit.has_method("can_accept_stack") and not hit.can_accept_stack(card.can_stack, card.can_stack_any):
		return null
	return hit

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
	if input_paused or _play_space_busy():
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

func _play_space_busy() -> bool:
	return play_space != null and play_space.has_method("is_dragging") and play_space.is_dragging()

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
	# pile with its hover lift still applied (which would put it above the
	# freshly-drawn cards).
	if _hovered_card == null:
		return
	_hovered_card.set_hovered(false)
	var idx := cards.find(_hovered_card)
	_hovered_card.z_index = ZLayers.HAND_FAN_BASE + idx if idx >= 0 else 0
	_hovered_card = null

func _start_drag(card: Card) -> void:
	_dragging_card = card
	_hovered_card = null
	card.set_hovered(false)
	card.start_drag()
	card.z_index = ZLayers.HAND_DRAG
	_drag_velocity = Vector2.ZERO
	_drag_last_pos = card.position
	_drag_velocity_seeded = false
	# Re-layout the remaining cards so the gap closes immediately.
	layout()

func _sample_drag_velocity(delta: float) -> void:
	if _dragging_card == null or delta <= 0.0:
		return
	var pos := _dragging_card.position
	if _drag_velocity_seeded:
		var inst_v: Vector2 = (pos - _drag_last_pos) / delta
		var blend := 1.0 - exp(-delta * DRAG_VELOCITY_RESPONSE)
		_drag_velocity = _drag_velocity.lerp(inst_v, blend)
	_drag_last_pos = pos
	_drag_velocity_seeded = true

func _end_drag() -> void:
	var card := _dragging_card
	_dragging_card = null
	if card.releases_on_threshold:
		if _card_clears_threshold(card) and _is_card_playable(card):
			# Released outside the hand zone with a playable card: remove and fly off.
			# Hand off the final drag velocity so the SETTLE phase carries the
			# card in the direction of the player's gesture before homing in.
			card.set_release_velocity(_drag_velocity)
			cards.erase(card)
			layout()
			card_played.emit(card, null)
		else:
			# Released inside the hand zone OR not playable: it slots back in.
			card.end_drag_return()
			layout()
	else:
		# Stack-target: only plays if a valid stack is currently targeted AND
		# the card is otherwise playable. Threshold doesn't apply — the player
		# might drop directly on a stack without raising the card high.
		var target = _last_targeted_planet
		_set_targeted_planet(null)
		if target != null and _is_card_playable(card):
			cards.erase(card)
			layout()
			card_played.emit(card, target)
		else:
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
			c.z_index = ZLayers.HAND_FAN_BASE + i
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
		_hovered_card.z_index = ZLayers.HAND_FAN_BASE + idx if idx >= 0 else 0
	_hovered_card = found
	if found != null:
		found.set_hovered(true)
		found.z_index = ZLayers.HAND_HOVER
		if hover_audio != null:
			hover_audio.play()

func _point_in_card(card: Card, world_point: Vector2) -> bool:
	# Hit-test against the rest pose, expanded upward to cover the hover lift.
	var hand_local := to_local(world_point)
	var rest_xform := Transform2D(card.rest_rotation, card.rest_position)
	var card_local := rest_xform.affine_inverse() * hand_local
	var rect := Rect2(
		Vector2(-Card.SIZE.x * 0.5, -Card.SIZE.y * 0.5 - Card.HOVER_LIFT),
		Vector2(Card.SIZE.x, Card.SIZE.y + Card.HOVER_LIFT))
	return rect.has_point(card_local)
