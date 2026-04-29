class_name PlanetCard extends Node2D

# A draggable card that represents one settled planet on the play space.
# Shares the player-card footprint (120×168). Buildings stack solitaire-style
# BELOW the planet at full size, with the planet card forming the visual
# top of one clean column — each newer building is added one step further
# down and rendered in front of the older ones, so the planet body and the
# cards above each one cover all but its bottom peek.
#
# Pickable + physical boundary: the planet body and its building stack are
# treated as a single rectangular region (see get_local_bounds). Clicks on
# the stack pick up the planet for dragging, drag-played cards target the
# planet when dropped anywhere over that rectangle, and inter-planet
# separation pushes neighbours so the rectangles never overlap.

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
# scale. Each new card sits BUILDING_STEP px below the previous and renders
# in front of it, so only the bottom peek (height STEP) of each card below
# the planet is visible — solitaire-style, with the planet body itself
# acting as the top card of the column.
const BUILDING_CARD_SCALE := Vector2.ONE
const BUILDING_STEP := 28.0

@onready var _body: Panel = $Body
@onready var _name_label: Label = $Body/NameLabel
@onready var _type_label: Label = $Body/TypeLabel
@onready var _sphere: ColorRect = $Sphere
@onready var _buildings_root: Node2D = $Buildings
@onready var _click_area: Area2D = $ClickArea
@onready var _click_shape: CollisionShape2D = $ClickArea/CollisionShape2D

# Per-type sphere base colors. The sphere shader lights this base color as a
# fake 3D ball; multi-type planets average the entries below so e.g. an
# "Ice/Oceanic" world reads as pale blue between cyan and deep blue.
const TYPE_COLORS := {
	"Rocky": Color(0.55, 0.42, 0.30),
	"Oceanic": Color(0.20, 0.45, 0.85),
	"Ice": Color(0.78, 0.92, 1.00),
	"Gas Giant": Color(0.88, 0.66, 0.38),
}
const FALLBACK_TYPE_COLOR := Color(0.5, 0.5, 0.5)

var data = null                       # GameState.PlanetData (typed Variant — autoload class)
var targeted: bool = false
var selected: bool = false
var draggable_in_bounds: bool = true

# Visual cards corresponding 1:1 to data.buildings entries. Owned by this
# planet card (children of _buildings_root). Kept in sync via attach + remove.
var _building_visuals: Array = []

# Padding (px) around each planet's pickable rectangle when checking for
# overlap with neighbours. Two planets' rectangles must keep this much
# clearance on every side, so dragging respects the same gap the random
# emitter respects.
const SEPARATION_PADDING := 14.0

# Only one planet can be dragged at a time. Tracked at class level so a
# second planet's Area2D click (e.g. from overlapping click areas, or a fast
# user clicking another planet mid-drag) is ignored.
static var _active_dragger: PlanetCard = null

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _body_stylebox: StyleBoxFlat = null

func _ready() -> void:
	_body_stylebox = (_body.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
	_body.add_theme_stylebox_override("panel", _body_stylebox)
	# The sphere material is a sub-resource shared by every PlanetCard instance
	# in the scene file. Duplicate so each planet's base_color is independent.
	if _sphere != null and _sphere.material != null:
		_sphere.material = _sphere.material.duplicate()
	_click_area.input_event.connect(_on_input_event)
	# Buildings render above the planet body. Inter-building order is set
	# per-card by attach_building_card so newer cards sit on top.
	_buildings_root.z_index = 1
	# The click shape sub-resource is shared across instances by the scene
	# file. Duplicate so each planet's shape can grow independently as its
	# building stack changes.
	if _click_shape != null and _click_shape.shape != null:
		_click_shape.shape = _click_shape.shape.duplicate()
	_update_click_area_shape()
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
	_apply_sphere_color()

func _apply_sphere_color() -> void:
	if _sphere == null or data == null:
		return
	var mat: ShaderMaterial = _sphere.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("base_color", _combined_type_color(data.planet_type))

func _combined_type_color(type_string: String) -> Color:
	# Splits the planet_type field on "/" or "," so a future multi-type planet
	# (e.g. "Ice/Oceanic") averages each component's color. Single-type strings
	# fall through to a one-entry average and look up unchanged.
	var parts := []
	for raw in type_string.replace("/", ",").split(","):
		var t := raw.strip_edges()
		if t != "":
			parts.append(t)
	if parts.is_empty():
		return FALLBACK_TYPE_COLOR
	var sum := Color(0, 0, 0, 0)
	for t in parts:
		sum += TYPE_COLORS.get(t, FALLBACK_TYPE_COLOR)
	var inv := 1.0 / float(parts.size())
	return Color(sum.r * inv, sum.g * inv, sum.b * inv, 1.0)

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
	# Newer cards (higher index) sit in front. settle_into_building_slot
	# resets z_index to 0, so set after.
	card.z_index = index
	_update_click_area_shape()

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
			c.z_index = i
	_update_click_area_shape()

func _building_slot_local(index: int) -> Vector2:
	# Local position (in _buildings_root coords) where the card centred at
	# slot `index` should sit. Buildings stack BELOW the planet: each card's
	# bottom is BUILDING_STEP px below the previous card's bottom. Card 0
	# sits so its bottom is BUILDING_STEP below the planet body's bottom
	# edge, leaving a clean STEP-tall peek for every card below the planet.
	var bottom_y := BODY_HALF.y + float(index + 1) * BUILDING_STEP
	return Vector2(0.0, bottom_y - Card.SIZE.y * 0.5)

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
		if draggable_in_bounds and _active_dragger == null:
			_dragging = true
			_active_dragger = self
			_drag_offset = global_position - get_global_mouse_position()
	else:
		_end_drag()

func _process(_delta: float) -> void:
	if _dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_end_drag()
			return
		var target := get_global_mouse_position() + _drag_offset
		global_position = target
		_resolve_against_siblings()
		if data != null:
			data.position = global_position

func _end_drag() -> void:
	_dragging = false
	if _active_dragger == self:
		_active_dragger = null

func _resolve_against_siblings() -> void:
	# Constrain this planet's position so its pickable rectangle doesn't
	# overlap any sibling's. Siblings are immovable — the dragger slides
	# along their edges instead of pushing them. Iterates a few times so
	# resolving against one neighbour can't leave us overlapping another.
	for _i in 4:
		var any_overlap := false
		var my_bounds := get_world_bounds()
		for sib in get_parent().get_children():
			if sib == self or not (sib is PlanetCard):
				continue
			var sib_bounds: Rect2 = sib.get_world_bounds()
			var push: Vector2 = _aabb_separation_push(sib_bounds, my_bounds, SEPARATION_PADDING)
			if push == Vector2.ZERO:
				continue
			global_position += push
			any_overlap = true
		if not any_overlap:
			return

static func _aabb_separation_push(a: Rect2, b: Rect2, padding: float) -> Vector2:
	# Vector to apply to b so that b no longer overlaps a (with `padding` of
	# clearance on every side). Returns Vector2.ZERO if already separated.
	# Resolves along whichever axis has the smaller required push.
	var a_inflated: Rect2 = a.grow(padding * 0.5)
	var b_inflated: Rect2 = b.grow(padding * 0.5)
	if not a_inflated.intersects(b_inflated):
		return Vector2.ZERO
	var a_center: Vector2 = a_inflated.position + a_inflated.size * 0.5
	var b_center: Vector2 = b_inflated.position + b_inflated.size * 0.5
	var dx := b_center.x - a_center.x
	var dy := b_center.y - a_center.y
	var overlap_x: float = (a_inflated.size.x + b_inflated.size.x) * 0.5 - absf(dx)
	var overlap_y: float = (a_inflated.size.y + b_inflated.size.y) * 0.5 - absf(dy)
	if overlap_x < overlap_y:
		var dir_x: float = signf(dx) if dx != 0.0 else 1.0
		return Vector2(dir_x * overlap_x, 0.0)
	var dir_y: float = signf(dy) if dy != 0.0 else 1.0
	return Vector2(0.0, dir_y * overlap_y)

func get_local_bounds() -> Rect2:
	# Rectangle (in this PlanetCard's local coords) covering the planet body
	# plus the building stack hanging below it. The stack adds BUILDING_STEP
	# of height per attached building, since each new card peeks out by that
	# much past the previous one's bottom edge.
	var stack_extra: float = float(_building_visuals.size()) * BUILDING_STEP
	return Rect2(-BODY_HALF.x, -BODY_HALF.y, SIZE.x, SIZE.y + stack_extra)

func get_world_bounds() -> Rect2:
	# Same rectangle as get_local_bounds, translated by global_position.
	# Note: the play space's scale (zoom) isn't applied here because both
	# this planet and any sibling we compare against share the same parent,
	# so working in their common parent space is sufficient.
	var b := get_local_bounds()
	b.position += global_position
	return b

func _update_click_area_shape() -> void:
	# Resize the ClickArea collision rectangle so it covers the current
	# planet+stack region. The shape's local origin is the ClickArea's
	# center, so a non-symmetric (downward-growing) bounds rectangle is
	# accommodated by offsetting the CollisionShape2D rather than the shape.
	if _click_shape == null:
		return
	var rect: Rect2 = get_local_bounds()
	var rs: RectangleShape2D = _click_shape.shape as RectangleShape2D
	if rs == null:
		return
	rs.size = rect.size
	_click_shape.position = rect.position + rect.size * 0.5

func contains_point(world_point: Vector2) -> bool:
	# Hit test for "planet under cursor" while dragging a player card. The
	# planet body and its building stack are treated as one region so a
	# card dropped anywhere over the column targets this planet.
	var local := to_local(world_point)
	return get_local_bounds().has_point(local)
