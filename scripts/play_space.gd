class_name PlaySpace extends Node2D

# Hosts settled planet cards. Owns planet emission (card-back arc from the
# planet deck → settle into a grid cell).

const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")
const PLANET_CARD_SCENE := preload("res://scenes/planet_card.tscn")
const CARD_SCENE := preload("res://scenes/card.tscn")

# Grid cell size. Cards are 120×168; the extra margin keeps neighbours apart.
const CELL_W := 150
const CELL_H := 210

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
const PAN_DRAG_THRESHOLD := 4.0

# Drop-preview colors. Slightly lighter fill than the card background so the
# ghost reads clearly without fighting the card that will land there.
const PREVIEW_FILL   := Color(0.26, 0.31, 0.44, 0.85)
const PREVIEW_BORDER := Color(0.55, 0.60, 0.72, 0.70)

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

# Set by main.gd. Read to defer to hand interactions when deciding whether to
# start a pan.
var hand: Node = null

# Set true while a full-screen modal is up.
var input_paused: bool = false:
	set(value):
		input_paused = value
		if value and _hovered_planet != null and is_instance_valid(_hovered_planet):
			_hovered_planet.set_hovered(false)
			_hovered_planet = null

# Grid: tracks which cells are occupied. Key = Vector2i cell, value = PlanetCard.
var _occupied: Dictionary = {}

# Drop-preview state. Drawn via _draw() on this node so it sits below planets.
var _preview_visible: bool = false
var _preview_cell: Vector2i = Vector2i.ZERO

func set_planet_deck_position(world_pos: Vector2) -> void:
	_planet_deck_position = world_pos

func _process(_delta: float) -> void:
	var dragger = PlanetCard._active_dragger
	if dragger != null and is_instance_valid(dragger):
		var cell := _nearest_empty_cell(dragger.position)
		if not _preview_visible or cell != _preview_cell:
			_preview_visible = true
			_preview_cell = cell
			queue_redraw()
	elif _preview_visible:
		_preview_visible = false
		queue_redraw()

func _draw() -> void:
	if not _preview_visible:
		return
	var center := cell_to_world(_preview_cell)
	var rect := Rect2(center - PlanetCard.BODY_HALF, PlanetCard.SIZE)
	draw_rect(rect, PREVIEW_FILL, true)
	draw_rect(rect, PREVIEW_BORDER, false, 2.0)

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
	# screen_pos remains at screen_pos after the scale change.
	var current := scale.x
	var target: float = clampf(current * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(target, current):
		return
	var ratio := target / current
	position = screen_pos + (position - screen_pos) * ratio
	scale = Vector2(target, target)

func get_planet_under_cursor(world_point: Vector2):
	# Return the topmost PlanetCard under the cursor, or null.
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
	# Used for the homeworld and journal card at game start — no arc, just
	# appear. Snaps local_pos to the nearest empty grid cell.
	var cell := _nearest_empty_cell(local_pos)
	var snapped := cell_to_world(cell)
	var pc := _spawn_planet(planet_data, snapped, cell)
	pc.scale = Vector2.ONE
	return pc

func find_card_by_tag(tag: String) -> PlanetCard:
	# Locate a board card whose data carries `tag` (e.g. "journal", "alien_ship").
	for child in _planets_container.get_children():
		if child is PlanetCard and child.data != null and tag in child.data.card_types:
			return child
	return null

func has_card_with_tag(tag: String) -> bool:
	return find_card_by_tag(tag) != null

func emit_journal_entry(entry: CardData) -> void:
	# Animate a card-back from the planet-deck position to the journal card's
	# location, then swap in a real Card and stack it onto the journal.
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
	# Animate a card-back from the planet-deck position arcing into an empty
	# grid cell visible on screen, then swap in a real PlanetCard.
	var cell := find_empty_cell_in_view()
	var target := cell_to_world(cell)
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
	tween.finished.connect(_on_emit_arc_done.bind(back, planet_data, target, cell))

func _arc_back(t: float, back: Node2D, start: Vector2, control: Vector2, end: Vector2) -> void:
	var u := 1.0 - t
	back.global_position = u * u * start + 2.0 * u * t * control + t * t * end

func _on_emit_arc_done(back: Node2D, planet_data, target: Vector2, cell: Vector2i) -> void:
	back.queue_free()
	var pc := _spawn_planet(planet_data, target, cell)
	pc.play_settle_in()
	GameState.planet_settled.emit(planet_data)

func _spawn_planet(planet_data, local_pos: Vector2, cell: Vector2i) -> PlanetCard:
	var pc: PlanetCard = PLANET_CARD_SCENE.instantiate()
	_planets_container.add_child(pc)
	pc.position = local_pos
	pc.play_space = self
	pc.grid_cell = cell
	pc.bind_data(planet_data)
	planet_data.position = local_pos
	_occupied[cell] = pc
	return pc

# --- Grid utilities ---

static func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(roundi(pos.x / CELL_W), roundi(pos.y / CELL_H))

static func cell_to_world(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL_W, cell.y * CELL_H)

func _get_visible_rect_local() -> Rect2:
	var vp := get_viewport_rect()
	var tl := to_local(vp.position)
	var br := to_local(vp.end)
	return Rect2(minf(tl.x, br.x), minf(tl.y, br.y), absf(br.x - tl.x), absf(br.y - tl.y))

func find_empty_cell_in_view() -> Vector2i:
	# Find the empty cell closest to the screen center within the visible area.
	# Falls back to a spiral search if every visible cell is occupied.
	var vr := _get_visible_rect_local()
	if vr.size == Vector2.ZERO:
		return _find_empty_cell_spiral(Vector2i.ZERO)
	var center_cell := world_to_cell(vr.get_center())
	var min_col := floori(vr.position.x / CELL_W)
	var max_col := ceili(vr.end.x / CELL_W)
	var min_row := floori(vr.position.y / CELL_H)
	var max_row := ceili(vr.end.y / CELL_H)
	var candidates: Array = []
	for row in range(min_row, max_row + 1):
		for col in range(min_col, max_col + 1):
			var cell := Vector2i(col, row)
			if not _occupied.has(cell):
				candidates.append(cell)
	if candidates.is_empty():
		return _find_empty_cell_spiral(center_cell)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da := (Vector2(a) - Vector2(center_cell)).length_squared()
		var db := (Vector2(b) - Vector2(center_cell)).length_squared()
		return da < db
	)
	return candidates[0]

func _nearest_empty_cell(pos: Vector2) -> Vector2i:
	return _find_empty_cell_spiral(world_to_cell(pos))

func _find_empty_cell_spiral(center: Vector2i) -> Vector2i:
	# Expand outward in square rings until an empty cell is found.
	for radius in range(0, 200):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) == radius or abs(dy) == radius:
					var cell := center + Vector2i(dx, dy)
					if not _occupied.has(cell):
						return cell
	return center

# --- Cell ownership ---

func release_cell(planet: PlanetCard) -> void:
	if _occupied.get(planet.grid_cell) == planet:
		_occupied.erase(planet.grid_cell)

func snap_planet_to_grid(planet: PlanetCard) -> void:
	var cell := _nearest_empty_cell(planet.position)
	planet.grid_cell = cell
	_occupied[cell] = planet
	var target := cell_to_world(cell)
	planet.position = target
	if planet.data != null:
		planet.data.position = target
