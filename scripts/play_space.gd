class_name PlaySpace extends Node2D

# Hosts settled planet cards and trade-route lines. Owns planet emission
# (card-back arc from the planet deck → settle into a non-overlapping spot).
#
# Relays planet_clicked from each child PlanetCard so main.gd can switch on
# game phase to decide whether the click means "select for trade route" or
# "manual reposition".

signal planet_clicked(planet)

const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")
const PLANET_CARD_SCENE := preload("res://scenes/planet_card.tscn")

# Bounds within which planets settle. Wider than the manual-reposition bounds
# in PlanetCard because the play space spans most of the screen.
const PLAY_BOUNDS := Rect2(20, 60, 1040, 470)
# Two planets must keep at least this much center-to-center clearance for the
# placement search to consider a candidate spot valid. Sized to keep the
# 120-wide card bodies clear of one another with a small gap; vertical building
# stacks may still overlap a neighbor's chips at max fill — players can drag
# planets to rearrange.
const COLLISION_RADIUS := 95.0
const PLACEMENT_TRIES := 12
# Card centers settle within these ranges. X leaves 60px (card half-width) of
# margin from each edge. Y is positioned in the lower half of the play area
# so a fully-built planet's solitaire stack — which now grows UPWARD from
# the planet card — has room to extend toward the top of the screen without
# clipping. The lower bound keeps the planet body clear of the hand at y≈580.
const SETTLE_X_RANGE := Vector2(100, 1000)
const SETTLE_Y_RANGE := Vector2(380, 470)

const EMIT_ARC_PEAK := 140.0
const EMIT_DURATION := 0.55

@onready var _planets_container: Node2D = $Planets
@onready var _routes_container: Node2D = $Routes

var _planet_deck_position: Vector2 = Vector2(1180, 40)

func set_planet_deck_position(world_pos: Vector2) -> void:
	_planet_deck_position = world_pos

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

func place_planet_immediate(planet_data, world_pos: Vector2) -> PlanetCard:
	# Used for the homeworld at game start — no arc, just appear.
	var pc := _spawn_planet(planet_data, world_pos)
	pc.scale = Vector2.ONE
	return pc

func emit_next_planet(planet_data) -> void:
	# Animate a card-back from the planet-deck position arcing into a
	# non-overlapping spot in the play space, then swap in a real PlanetCard.
	var target := _find_non_overlapping_position()
	planet_data.position = target

	var back: Node2D = CARD_BACK_SCENE.instantiate()
	add_child(back)
	back.global_position = _planet_deck_position
	back.z_index = 50

	var start := back.global_position
	var midpoint := (start + target) * 0.5
	var control := midpoint + Vector2(0.0, -EMIT_ARC_PEAK)

	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(_arc_back.bind(back, start, control, target), 0.0, 1.0, EMIT_DURATION)
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

func _spawn_planet(planet_data, world_pos: Vector2) -> PlanetCard:
	var pc: PlanetCard = PLANET_CARD_SCENE.instantiate()
	_planets_container.add_child(pc)
	pc.global_position = world_pos
	pc.bind_data(planet_data)
	planet_data.position = world_pos
	pc.planet_clicked.connect(_on_planet_clicked)
	return pc

func _on_planet_clicked(planet) -> void:
	planet_clicked.emit(planet)

func _find_non_overlapping_position() -> Vector2:
	var existing: Array = []
	for child in _planets_container.get_children():
		if child is PlanetCard:
			existing.append(child.global_position)
	for _i in PLACEMENT_TRIES:
		var c := Vector2(
			randf_range(SETTLE_X_RANGE.x, SETTLE_X_RANGE.y),
			randf_range(SETTLE_Y_RANGE.x, SETTLE_Y_RANGE.y))
		var ok := true
		for ep in existing:
			if c.distance_to(ep) < COLLISION_RADIUS * 2.0:
				ok = false
				break
		if ok:
			return c
	# Fallback: pick the candidate furthest from all existing planets.
	var best := Vector2((SETTLE_X_RANGE.x + SETTLE_X_RANGE.y) * 0.5,
		(SETTLE_Y_RANGE.x + SETTLE_Y_RANGE.y) * 0.5)
	var best_min_dist := -1.0
	for _i in 24:
		var c := Vector2(
			randf_range(SETTLE_X_RANGE.x, SETTLE_X_RANGE.y),
			randf_range(SETTLE_Y_RANGE.x, SETTLE_Y_RANGE.y))
		var min_d := INF
		for ep in existing:
			min_d = minf(min_d, c.distance_to(ep))
		if min_d > best_min_dist:
			best_min_dist = min_d
			best = c
	return best

# ---------------------------------------------------------------------------
# Trade route visuals (Phase 7 wiring lives in main.gd)

const TRADE_ROUTE_SCENE := preload("res://scenes/trade_route.tscn")

func add_trade_route_visual(planet_a: PlanetCard, planet_b: PlanetCard, data) -> Node:
	var route = TRADE_ROUTE_SCENE.instantiate()
	_routes_container.add_child(route)
	route.bind(planet_a, planet_b, data)
	return route

func clear_trade_routes() -> void:
	for c in _routes_container.get_children():
		c.queue_free()

func remove_trade_routes_for_planet(planet: PlanetCard) -> void:
	for c in _routes_container.get_children():
		if c.has_method("involves") and c.involves(planet):
			c.queue_free()
