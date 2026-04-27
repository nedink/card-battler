class_name TradeRoute extends Node2D

# Visual link between two PlanetCards. The Line2D's endpoints follow the
# planets each frame so manual repositioning of either end keeps the route
# attached.

const ACTIVE_COLOR := Color(0.4, 0.85, 0.5, 0.85)
const BLOCKED_COLOR := Color(0.55, 0.55, 0.55, 0.7)
const LINE_WIDTH := 5.0

@onready var _line: Line2D = $Line2D

var planet_a = null   # PlanetCard
var planet_b = null   # PlanetCard
var data = null       # GameState.TradeRouteData

func bind(p_a, p_b, p_data) -> void:
	planet_a = p_a
	planet_b = p_b
	data = p_data
	_apply_color()

func set_blocked(value: bool) -> void:
	if data != null:
		data.blocked = value
	_apply_color()

func _apply_color() -> void:
	if _line == null:
		return
	if data != null and data.blocked:
		_line.default_color = BLOCKED_COLOR
	else:
		_line.default_color = ACTIVE_COLOR

func involves(planet) -> bool:
	return planet == planet_a or planet == planet_b

func _process(_delta: float) -> void:
	if planet_a == null or planet_b == null:
		return
	if not is_instance_valid(planet_a) or not is_instance_valid(planet_b):
		queue_free()
		return
	_line.points = PackedVector2Array([
		to_local(planet_a.global_position),
		to_local(planet_b.global_position)
	])
	# Re-apply color in case GameState toggled blocked externally.
	if data != null:
		var want := BLOCKED_COLOR if data.blocked else ACTIVE_COLOR
		if _line.default_color != want:
			_line.default_color = want
