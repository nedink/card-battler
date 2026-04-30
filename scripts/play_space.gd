class_name PlaySpace extends Node2D

# Hosts settled planet cards. Owns planet emission (card-back arc from the
# planet deck → settle into a non-overlapping spot).

const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")
const PLANET_CARD_SCENE := preload("res://scenes/planet_card.tscn")
const CARD_SCENE := preload("res://scenes/card.tscn")

# Bounds within which planets settle. Wider than the manual-reposition bounds
# in PlanetCard because the play space spans most of the screen.
const PLAY_BOUNDS := Rect2(20, 60, 1040, 470)
const PLACEMENT_TRIES := 12
# Card centers settle within these ranges. X leaves 60px (card half-width) of
# margin from each edge.
const SETTLE_X_RANGE := Vector2(100, 1000)
const SETTLE_Y_RANGE := Vector2(380, 470)

const EMIT_ARC_PEAK := 140.0
const EMIT_DURATION := 0.55

# Mouse-wheel zoom on the play space. Scaling happens around the cursor so
# the world point under the mouse stays put.
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.0
const ZOOM_STEP := 1.1
# Region (screen coords) where wheel events are interpreted as zoom and where
# left-button drag-pan is initiated. Excludes the hand strip at the bottom so
# scrolling there doesn't zoom the play area.
const ZOOM_REGION := Rect2(0, 50, 1280, 510)

# Drag-to-pan: a left-button press on the background within ZOOM_REGION starts
# tracking, but pan only commits once the cursor has moved this many pixels.
# That way a click on a pile click-area inside ZOOM_REGION (e.g. PlanetDeck)
# doesn't jiggle the view when the user just meant to open its viewer.
const PAN_DRAG_THRESHOLD := 4.0

enum PanState { IDLE, PENDING, ACTIVE }

@onready var _planets_container: Node2D = $Planets

var _planet_deck_position: Vector2 = Vector2(1180, 40)

var _pan_state: int = PanState.IDLE
var _pan_start_screen: Vector2 = Vector2.ZERO
var _pan_start_position: Vector2 = Vector2.ZERO

# Currently hovered planet/stack (topmost under the cursor). Updated on mouse
# motion. Cleared while the hand is dragging a card so its `targeted` highlight
# is the sole signal during a card play.
var _hovered_planet: PlanetCard = null

# Set by main.gd. Read to defer to hand interactions (a hovered card, or a
# modal that paused the hand) when deciding whether to start a pan.
var hand: Node = null

# Set true while a full-screen modal is up. Mouse motion is already swallowed
# by the modal's backdrop so no new hovers can fire, but a planet that was
# hovered when the modal opened would otherwise stay highlighted underneath.
# Setting this clears the current hover and blocks subsequent updates.
var input_paused: bool = false:
	set(value):
		input_paused = value
		if value and _hovered_planet != null and is_instance_valid(_hovered_planet):
			_hovered_planet.set_hovered(false)
			_hovered_planet = null

func set_planet_deck_position(world_pos: Vector2) -> void:
	_planet_deck_position = world_pos

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _can_start_pan(mb.position):
					_pan_state = PanState.PENDING
					_pan_start_screen = mb.position
					_pan_start_position = position
			else:
				_pan_state = PanState.IDLE
			return
		if not mb.pressed:
			return
		if not ZOOM_REGION.has_point(mb.position):
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, ZOOM_STEP)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / ZOOM_STEP)
	elif event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _pan_state != PanState.IDLE:
			var delta: Vector2 = mm.position - _pan_start_screen
			if _pan_state == PanState.PENDING:
				if delta.length() < PAN_DRAG_THRESHOLD:
					return
				_pan_state = PanState.ACTIVE
			position = _pan_start_position + delta
		_update_hovered_planet(mm.position)

func _update_hovered_planet(screen_pos: Vector2) -> void:
	# Suppress the hover highlight while the hand is dragging a card — that
	# flow uses the `targeted` (yellow) border so its planet under the cursor
	# is unambiguous. Also suppressed while a modal has paused us.
	var hit = null
	if not input_paused and (hand == null or not hand.is_dragging()):
		hit = get_planet_under_cursor(screen_pos)
	if hit == _hovered_planet:
		return
	if _hovered_planet != null and is_instance_valid(_hovered_planet):
		_hovered_planet.set_hovered(false)
	_hovered_planet = hit
	if hit != null:
		hit.set_hovered(true)

func _can_start_pan(screen_pos: Vector2) -> bool:
	# Press initiates a pan only if the click would otherwise hit the empty
	# background. Planet clicks (Area2D) and hand-card drags both arrive on
	# the same press event, so we explicitly defer to them here — a planet
	# under the cursor or a hovered hand card means the click belongs to
	# them, not us.
	if not ZOOM_REGION.has_point(screen_pos):
		return false
	if get_planet_under_cursor(screen_pos) != null:
		return false
	if hand != null:
		if bool(hand.get("input_paused")):
			return false
		if hand.has_method("has_hovered_card") and hand.has_hovered_card():
			return false
	return true

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Anchor the zoom so the play-space point currently rendered at
	# screen_pos remains at screen_pos after the scale change. Derivation:
	# screen = position + scale * local; want local fixed → new_position =
	# screen - new_scale * (screen - position) / scale.
	var current := scale.x
	var target: float = clampf(current * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(target, current):
		return
	var ratio := target / current
	position = screen_pos + (position - screen_pos) * ratio
	scale = Vector2(target, target)

func get_planet_under_cursor(world_point: Vector2):
	# Return the topmost PlanetCard under the cursor, or null. Topmost = last
	# child (Godot draws children in order, last on top).
	var children := _planets_container.get_children()
	for i in range(children.size() - 1, -1, -1):
		var child = children[i]
		if child is PlanetCard and child.contains_point(world_point):
			return child
	return null

func get_planets() -> Array:
	var result: Array = []
	for child in _planets_container.get_children():
		if child is PlanetCard:
			result.append(child)
	return result

func place_planet_immediate(planet_data, local_pos: Vector2) -> PlanetCard:
	# Used for the homeworld and the journal card at game start — no arc, just
	# appear. local_pos is in this PlaySpace's local frame.
	var pc := _spawn_planet(planet_data, local_pos)
	pc.scale = Vector2.ONE
	return pc

func find_card_by_tag(tag: String) -> PlanetCard:
	# Locate a board card whose data carries `tag` (e.g. "journal", "alien_ship").
	# Returns the first match or null. Stable: there's at most one journal card,
	# and discovering the second alien ship just picks up whichever is topmost.
	for child in _planets_container.get_children():
		if child is PlanetCard and child.data != null and tag in child.data.card_types:
			return child
	return null

func has_card_with_tag(tag: String) -> bool:
	return find_card_by_tag(tag) != null

func emit_journal_entry(entry: CardData) -> void:
	# Animate a card-back from the planet-deck position to the journal card's
	# location, then swap in a real Card and stack it onto the journal. If the
	# journal card is missing (shouldn't happen mid-run) the entry is dropped.
	var journal := find_card_by_tag("journal")
	if journal == null:
		return
	var target_global: Vector2 = journal.global_position

	var back: Node2D = CARD_BACK_SCENE.instantiate()
	add_child(back)
	back.global_position = _planet_deck_position
	back.z_index = 50

	var start := back.global_position
	var midpoint := (start + target_global) * 0.5
	var control := midpoint + Vector2(0.0, -EMIT_ARC_PEAK)

	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(_arc_back.bind(back, start, control, target_global), 0.0, 1.0, EMIT_DURATION)
	tween.parallel().tween_property(back, "rotation", -PI, EMIT_DURATION)
	tween.parallel().tween_property(back, "scale", Vector2(1.4, 1.4), EMIT_DURATION)
	tween.finished.connect(_on_journal_arc_done.bind(back, entry, journal))

func _on_journal_arc_done(back: Node2D, entry: CardData, journal: PlanetCard) -> void:
	back.queue_free()
	if not is_instance_valid(journal):
		return
	var card: Card = CARD_SCENE.instantiate()
	add_child(card)
	card.global_position = journal.global_position
	card.configure(entry)
	journal.attach_building_card(card)

func emit_next_planet(planet_data) -> void:
	# Animate a card-back from the planet-deck position arcing into a
	# non-overlapping spot in the play space, then swap in a real PlanetCard.
	# `target` is in PlaySpace-local space; the arc itself drives global
	# position so it can fly from the planet deck (a sibling under main, in
	# global coords) — convert once when seeding the tween.
	var target := _find_non_overlapping_position()
	planet_data.position = target
	var target_global := to_global(target)

	var back: Node2D = CARD_BACK_SCENE.instantiate()
	add_child(back)
	back.global_position = _planet_deck_position
	back.z_index = 50

	var start := back.global_position
	var midpoint := (start + target_global) * 0.5
	var control := midpoint + Vector2(0.0, -EMIT_ARC_PEAK)

	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(_arc_back.bind(back, start, control, target_global), 0.0, 1.0, EMIT_DURATION)
	tween.parallel().tween_property(back, "rotation", -PI, EMIT_DURATION)
	tween.parallel().tween_property(back, "scale", Vector2(1.4, 1.4), EMIT_DURATION)
	tween.finished.connect(_on_emit_arc_done.bind(back, planet_data, target))

func _arc_back(t: float, back: Node2D, start: Vector2, control: Vector2, end: Vector2) -> void:
	var u := 1.0 - t
	back.global_position = u * u * start + 2.0 * u * t * control + t * t * end

func _on_emit_arc_done(back: Node2D, planet_data, target: Vector2) -> void:
	back.queue_free()
	var pc := _spawn_planet(planet_data, target)
	pc.play_settle_in()
	GameState.planet_settled.emit(planet_data)

func _spawn_planet(planet_data, local_pos: Vector2) -> PlanetCard:
	# `local_pos` is in this PlaySpace's local frame (the same frame
	# _find_non_overlapping_position generates candidates in). Setting `position`
	# rather than `global_position` keeps the spawn in the right spot when the
	# play space is zoomed or panned.
	var pc: PlanetCard = PLANET_CARD_SCENE.instantiate()
	_planets_container.add_child(pc)
	pc.position = local_pos
	pc.bind_data(planet_data)
	planet_data.position = local_pos
	return pc

func _find_non_overlapping_position() -> Vector2:
	# A new planet has no buildings yet, so its candidate AABB is just the
	# 120×168 body footprint, separation-padded. We check that footprint
	# against every existing planet's full (body + stack) world bounds so
	# the random emitter respects the same boundary the drag code does.
	var existing_bounds: Array = []
	for child in _planets_container.get_children():
		if child is PlanetCard:
			existing_bounds.append(child.get_world_bounds())
	var pad: float = PlanetCard.SEPARATION_PADDING
	for _i in PLACEMENT_TRIES:
		var c := Vector2(
			randf_range(SETTLE_X_RANGE.x, SETTLE_X_RANGE.y),
			randf_range(SETTLE_Y_RANGE.x, SETTLE_Y_RANGE.y))
		var candidate := _candidate_body_bounds(c)
		if _candidate_clear(candidate, existing_bounds, pad):
			return c
	# Fallback: pick the candidate furthest from all existing planet centers.
	var best := Vector2((SETTLE_X_RANGE.x + SETTLE_X_RANGE.y) * 0.5,
		(SETTLE_Y_RANGE.x + SETTLE_Y_RANGE.y) * 0.5)
	var best_min_dist := -1.0
	for _i in 24:
		var c := Vector2(
			randf_range(SETTLE_X_RANGE.x, SETTLE_X_RANGE.y),
			randf_range(SETTLE_Y_RANGE.x, SETTLE_Y_RANGE.y))
		var min_d := INF
		for eb in existing_bounds:
			var ec: Vector2 = eb.position + eb.size * 0.5
			min_d = minf(min_d, c.distance_to(ec))
		if min_d > best_min_dist:
			best_min_dist = min_d
			best = c
	return best

static func _candidate_body_bounds(center: Vector2) -> Rect2:
	# World-space AABB for a fresh (no-buildings) planet centred at `center`.
	return Rect2(center - PlanetCard.BODY_HALF, PlanetCard.SIZE)

static func _candidate_clear(candidate: Rect2, existing_bounds: Array, pad: float) -> bool:
	var inflated: Rect2 = candidate.grow(pad * 0.5)
	for eb in existing_bounds:
		var other: Rect2 = (eb as Rect2).grow(pad * 0.5)
		if inflated.intersects(other):
			return false
	return true
