class_name PlaySpace extends Node2D

# The play area: a grid of cells; each cell holds at most one stack of cards.
# A stack is a parent-child chain in the scene tree — the chain root is a
# direct child of `Stacks`, and each successive card is a child of the previous.
# Dragging a stack root therefore moves its whole subtree because Godot's
# Node2D transform inherits down the tree.
#
# PlaySpace owns:
#  - The grid: cell ↔ stack-root bookkeeping in `_occupied`.
#  - All input within the play area: pan, zoom, hover-highlight, drag pickup,
#    and drop dispatch (snap-to-empty-cell or stack-onto-target).
#  - Spawn animations (emit-arc from the planet deck).
#
# Hand cards are owned by Hand. When Hand decides a hand-drag should play onto
# a board card, main.gd calls `attach_card_to_stack(card, target)` directly —
# the same final step PlaySpace uses for board-drag drops.

const CARD_SCENE := preload("res://scenes/card.tscn")
const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")

# Grid cell size = card body + 4px gutter on each axis. Neighbour stacks share
# this 4px breathing room; deeper stacks peek down past the cell into whatever
# row sits below (the grid is just an aesthetic anchor, not a clipping bound).
const GUTTER := 4
const CELL_W := int(Card.SIZE.x) + GUTTER  # 124
const CELL_H := int(Card.SIZE.y) + GUTTER  # 172

# Spawn arc anim.
const EMIT_ARC_PEAK := 140.0
const EMIT_DURATION := 0.55

# Drop-snap (root → empty cell) tween.
const SNAP_DURATION := 0.18

# Pan/zoom.
const ZOOM_MIN := 0.5
const ZOOM_MAX := 2.0
const ZOOM_STEP := 1.1
# Region (screen coords) where wheel events zoom the play space and where a
# left-button drag on background starts a pan. Excludes the hand strip.
const ZOOM_REGION := Rect2(0, 50, 1280, 510)
const PAN_DRAG_THRESHOLD := 4.0

# Cursor must move this far before a press on a board card promotes from
# PENDING to ACTIVE drag — lets a quick click-and-release stay a click.
const DRAG_PROMOTE_THRESHOLD := 4.0

# Stack z-ordering: a settled root's z follows its cell y so southerly
# stacks render in front of northerly ones; hover/drag lift the whole chain
# (children inherit z_index relatively, so the lift cascades). All values
# come from ZLayers — see the band layout in z_layers.gd.

# Drop-preview rectangle drawn under stacks when targeting an empty cell.
# Rounded corners match Card's body radius (see scenes/card.tscn).
const PREVIEW_FILL := Color(0.26, 0.31, 0.44, 0.85)
const PREVIEW_CORNER_RADIUS := 8

enum DragState { NONE, PENDING, ACTIVE }
enum PanState { IDLE, PENDING, ACTIVE }

@onready var _stacks_container: Node2D = $Stacks

# Cell → chain-root Card. The single source of truth for "which cells are taken".
var _occupied: Dictionary = {}

# Drag state for board pickup. The whole subtree of `_drag_root` follows the
# cursor while ACTIVE.
var _drag_state: int = DragState.NONE
var _drag_root: Card = null
var _drag_offset_local: Vector2 = Vector2.ZERO   # cursor → root, in our local frame
var _drag_origin_cell: Vector2i = Vector2i.ZERO
var _drag_press_screen: Vector2 = Vector2.ZERO

# Hover (when no drag is in progress). _hovered_card is the actual deepest
# card under the cursor (so its border lights up and the chain-step layout
# expands the slot just below it); _hovered_root is its chain root, tracked
# separately so hover-z lift covers the whole stack.
var _hovered_card: Card = null
var _hovered_root: Card = null

# Pan state.
var _pan_state: int = PanState.IDLE
var _pan_start_screen: Vector2 = Vector2.ZERO
var _pan_start_position: Vector2 = Vector2.ZERO

# Drop-preview state, drawn via _draw().
var _preview_visible: bool = false
var _preview_cell: Vector2i = Vector2i.ZERO
var _preview_stylebox: StyleBoxFlat = null

# Set true while a modal is up. Suppresses hover/drag and cancels any in-flight
# drag (returning the dragged stack to its origin cell so we don't lose state).
var input_paused: bool = false:
	set(value):
		input_paused = value
		if value:
			_clear_hover()
			if _drag_state != DragState.NONE:
				_cancel_drag(true)

# Set by main.gd. Used to defer when the hand is busy.
var hand: Node = null

# Anchor where card-back arcs originate. Set by main.gd from the planet deck's
# global position.
var _planet_deck_position: Vector2 = Vector2(1180, 40)

func set_planet_deck_position(world_pos: Vector2) -> void:
	_planet_deck_position = world_pos

# ---------------------------------------------------------------------------
# Public board API

func place_card_immediate(data: CardData, local_pos: Vector2) -> Card:
	# Used at game start for homeworld and journal anchor. No arc — just place.
	var cell := _nearest_empty_cell(local_pos)
	var c := _spawn_card(data, _cell_to_local(cell), cell)
	c.scale = Vector2.ONE
	return c

func find_root_with_tag(tag: String) -> Card:
	# First chain root whose chain contains a card carrying `tag`. (Walks the
	# chain so e.g. "alien_ship" anchors with a building stacked on them are
	# still findable.)
	for r in _roots():
		var n: Card = r
		while n != null:
			if tag in n.card_types:
				return r
			n = Card.next_chain_child(n)
	return null

func has_card_with_tag(tag: String) -> bool:
	return find_root_with_tag(tag) != null

func is_dragging() -> bool:
	return _drag_state == DragState.ACTIVE

# All Cards on the board, walking every chain. Order is unspecified — caller
# does not need a specific traversal.
func all_cards() -> Array[Card]:
	var out: Array[Card] = []
	for r in _roots():
		_collect_chain(r, out)
	return out

func _collect_chain(root: Card, out: Array[Card]) -> void:
	var n: Card = root
	while n != null:
		out.append(n)
		n = Card.next_chain_child(n)

# Drop a hand-owned `card` onto `target`. Hand calls this (via main.gd) when
# the player releases a draggable hand card over a stack with a matching top.
func attach_card_to_stack(card: Card, target: Card) -> void:
	target.attach_below(card)

# Public alias for hit testing — mirrors the old name some external callers
# used (Hand). Returns the topmost card under the cursor, or null.
func get_planet_under_cursor(screen_pos: Vector2) -> Card:
	return _find_card_under(screen_pos, null)

# ---------------------------------------------------------------------------
# Per-frame: drop preview while dragging.

func _process(_delta: float) -> void:
	if input_paused:
		return
	if _drag_state == DragState.ACTIVE and _drag_root != null:
		_update_drop_preview()
	elif _preview_visible:
		_preview_visible = false
		queue_redraw()

func _update_drop_preview() -> void:
	# A board-drag drop always snaps to an empty cell — chain roots are world
	# anchors (planets / journals / ships) which don't merge with each other,
	# so highlight where the dragged stack will land.
	var cell := _nearest_empty_cell(_cursor_local())
	if not _preview_visible or _preview_cell != cell:
		_preview_visible = true
		_preview_cell = cell
		queue_redraw()

func _draw() -> void:
	if not _preview_visible:
		return
	if _preview_stylebox == null:
		_preview_stylebox = StyleBoxFlat.new()
		_preview_stylebox.bg_color = PREVIEW_FILL
		_preview_stylebox.corner_radius_top_left = PREVIEW_CORNER_RADIUS
		_preview_stylebox.corner_radius_top_right = PREVIEW_CORNER_RADIUS
		_preview_stylebox.corner_radius_bottom_left = PREVIEW_CORNER_RADIUS
		_preview_stylebox.corner_radius_bottom_right = PREVIEW_CORNER_RADIUS
	var center := _cell_to_local(_preview_cell)
	var rect := Rect2(center - Card.SIZE * 0.5, Card.SIZE)
	draw_style_box(_preview_stylebox, rect)

# ---------------------------------------------------------------------------
# Input

func _unhandled_input(event: InputEvent) -> void:
	if input_paused:
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)

func _handle_mouse_button(mb: InputEventMouseButton) -> void:
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_on_left_press(mb)
		else:
			_on_left_release(mb)
		return
	if not mb.pressed:
		return
	if not ZOOM_REGION.has_point(mb.position):
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(mb.position, ZOOM_STEP)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(mb.position, 1.0 / ZOOM_STEP)

func _handle_mouse_motion(mm: InputEventMouseMotion) -> void:
	# Drag promotion: a press waiting in PENDING flips to ACTIVE once the
	# cursor has moved enough to read as "drag" rather than "click".
	if _drag_state == DragState.PENDING:
		if (mm.position - _drag_press_screen).length() >= DRAG_PROMOTE_THRESHOLD:
			_begin_drag_active()
	if _drag_state == DragState.ACTIVE:
		_drive_drag()
		# Eat the event so Hand and other listeners don't react under the
		# cursor while we're dragging a stack.
		get_viewport().set_input_as_handled()
		return
	if _pan_state != PanState.IDLE:
		var delta: Vector2 = mm.position - _pan_start_screen
		if _pan_state == PanState.PENDING:
			if delta.length() < PAN_DRAG_THRESHOLD:
				return
			_pan_state = PanState.ACTIVE
		position = _pan_start_position + delta
		return
	_update_hover_under(mm.position)

func _on_left_press(mb: InputEventMouseButton) -> void:
	if hand != null and hand.has_method("is_dragging") and hand.is_dragging():
		# Hand is busy with its own drag; don't steal input.
		return
	var hit := _find_card_under(mb.position, null)
	if hit != null:
		# Pick up the stack rooted at this hit's chain root (top-card-only
		# pickup; the whole chain comes along via parent-chain transforms).
		_begin_drag_pending(hit.get_chain_root(), mb.position)
		get_viewport().set_input_as_handled()
		return
	if _can_start_pan(mb.position):
		_pan_state = PanState.PENDING
		_pan_start_screen = mb.position
		_pan_start_position = position

func _on_left_release(mb: InputEventMouseButton) -> void:
	if _drag_state != DragState.NONE:
		_end_drag()
		get_viewport().set_input_as_handled()
		return
	_pan_state = PanState.IDLE

# ---------------------------------------------------------------------------
# Drag flow

func _begin_drag_pending(root: Card, screen_pos: Vector2) -> void:
	_drag_state = DragState.PENDING
	_drag_root = root
	_drag_press_screen = screen_pos
	_drag_origin_cell = root.grid_cell

func _begin_drag_active() -> void:
	if _drag_root == null:
		_drag_state = DragState.NONE
		return
	_drag_state = DragState.ACTIVE
	# Root must currently be a child of _stacks_container — capture cursor offset.
	var cur_local := _cursor_local()
	_drag_offset_local = _drag_root.position - cur_local
	# Free the source cell so other cards can flow into it during drag.
	_release_cell(_drag_root)
	# Ensure the dragged subtree renders above everything else.
	_drag_root.z_index = ZLayers.DRAG
	# Drop hover so two highlights don't fight.
	_clear_hover()
	# Collapse the dragged stack's peek so it reads as one chunk while flying.
	# _clear_hover above already cleared _hover_card_in_chain on whatever root
	# was previously hovered — but the dragged root may not be that one, so
	# clear and snap explicitly.
	_drag_root._hover_card_in_chain = null
	_drag_root._snap_chain_layout()
	_drag_root._step = Card.STEP_COLLAPSED

func _drive_drag() -> void:
	if _drag_root == null:
		return
	var cur_local := _cursor_local()
	_drag_root.position = cur_local + _drag_offset_local

func _end_drag() -> void:
	# A press without movement (PENDING) is a click — no drop dispatch.
	if _drag_state == DragState.PENDING:
		_drag_state = DragState.NONE
		_drag_root = null
		return
	var root := _drag_root
	_drag_state = DragState.NONE
	_drag_root = null
	_preview_visible = false
	queue_redraw()
	if root == null or not is_instance_valid(root):
		return
	# Board-drag drops always snap to an empty cell. Stack-merging is a hand-
	# card concern only — chain roots on the board are world anchors which
	# don't combine with each other.
	var cell := _nearest_empty_cell(_cursor_local())
	_settle_root_at_cell(root, cell)

func _cancel_drag(restore: bool) -> void:
	if _drag_state == DragState.NONE:
		return
	var root := _drag_root
	_drag_state = DragState.NONE
	_drag_root = null
	_preview_visible = false
	queue_redraw()
	if root != null and is_instance_valid(root) and restore:
		_settle_root_at_cell(root, _drag_origin_cell)

func _settle_root_at_cell(root: Card, cell: Vector2i) -> void:
	# If the target cell is taken (e.g. between PENDING and drop, another stack
	# moved into the original spot), pick a free one near it instead.
	if _occupied.has(cell) and _occupied[cell] != root:
		cell = _nearest_empty_cell(_cell_to_local(cell))
	if root.get_parent() != _stacks_container:
		root.reparent(_stacks_container)
	root.set_state_idle_board()
	root.grid_cell = cell
	# Snap natural-z immediately to the target row, even while the position
	# tweens — keeps neighbour layering correct mid-flight.
	_apply_natural_z(root)
	var target := _cell_to_local(cell)
	var t := root.create_tween()
	t.tween_property(root, "position", target, SNAP_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_occupied[cell] = root

func _release_cell(root: Card) -> void:
	if _occupied.get(root.grid_cell) == root:
		_occupied.erase(root.grid_cell)

# ---------------------------------------------------------------------------
# Spawn

func _spawn_card(data: CardData, local_pos: Vector2, cell: Vector2i) -> Card:
	var c: Card = CARD_SCENE.instantiate()
	_stacks_container.add_child(c)
	c.position = local_pos
	c.grid_cell = cell
	c.configure(data)
	c.set_state_idle_board()
	_apply_natural_z(c)
	_occupied[cell] = c
	return c

# Restore a stack root's z_index to "natural order": southernmost (largest y)
# renders in front. Anchored to the cell's y so a mid-tween position doesn't
# desync the layering. Children of the root inherit z relatively (+1 each level)
# so the whole chain stays correctly layered against neighbours.
func _apply_natural_z(root: Card) -> void:
	root.z_index = clampi(int(_cell_to_local(root.grid_cell).y), -ZLayers.NATURAL_RANGE, ZLayers.NATURAL_RANGE)

# ---------------------------------------------------------------------------
# Hover

func _update_hover_under(screen_pos: Vector2) -> void:
	# Suppress hover when something else owns interaction: a board drag (we'd
	# already early-returned), a hand drag (uses targeted highlight), or a
	# pan in progress.
	if hand != null and hand.has_method("is_dragging") and hand.is_dragging():
		_clear_hover()
		return
	if _pan_state == PanState.ACTIVE:
		_clear_hover()
		return
	var hit := _find_card_under(screen_pos, null)
	if hit == _hovered_card:
		return
	_clear_hover()
	_hovered_card = hit
	if hit != null:
		_hovered_root = hit.get_chain_root()
		hit.set_hovered(true)
		# Lift the whole chain above settled neighbours while hovered (children
		# inherit z relative to root, so the lift cascades for free).
		_hovered_root.z_index = ZLayers.HOVER
		# Expand the slot directly below the hovered card so just that card's
		# body reveals more — descendants are pushed down by the extra peek
		# but stay at STEP_COLLAPSED relative to each other.
		_hovered_root.set_chain_hover_target(hit)

func _clear_hover() -> void:
	if _hovered_card != null and is_instance_valid(_hovered_card):
		_hovered_card.set_hovered(false)
	if _hovered_root != null and is_instance_valid(_hovered_root):
		_hovered_root.set_chain_hover_target(null)
		_apply_natural_z(_hovered_root)
	_hovered_card = null
	_hovered_root = null

# ---------------------------------------------------------------------------
# Hit testing
#
# The chain is parent→child along scene order, with newer cards in front
# (z = parent_z + 1). We want to return the topmost-rendered card under the
# cursor, which is the deepest descendant in the chain that contains the point.
#
# Hover-expansion compensation: when a card in the chain is hovered, its child
# sits at STEP_EXPANDED instead of STEP_COLLAPSED, which visually pushes that
# child and every later descendant down by (STEP_EXPANDED - STEP_COLLAPSED).
# We intentionally do NOT push their hit areas down with them — the player
# should only need to travel STEP_COLLAPSED to move the hover from one card
# to the next, regardless of how much the slot has expanded. Walking the
# chain we accumulate each card's shift-from-collapsed and shift the world
# test point by the same amount before testing, so each card is hit-tested
# at its collapsed position.

func _find_card_under(world_point: Vector2, exclude_root: Card) -> Card:
	var best: Card = null
	var best_depth: int = -1
	var s := scale.y
	for r in _roots():
		if r == exclude_root:
			continue
		var n: Card = r
		var depth := 0
		var visual_offset_local := 0.0
		while n != null:
			var test_pt := world_point + Vector2(0.0, visual_offset_local * s)
			if n.contains_point_world(test_pt):
				if depth > best_depth:
					best_depth = depth
					best = n
			var next := Card.next_chain_child(n)
			if next != null:
				visual_offset_local += next._step - Card.STEP_COLLAPSED
			n = next
			depth += 1
	return best

func _roots() -> Array[Card]:
	var arr: Array[Card] = []
	for child in _stacks_container.get_children():
		if child is Card:
			arr.append(child)
	return arr

# ---------------------------------------------------------------------------
# Pan / zoom

func _can_start_pan(screen_pos: Vector2) -> bool:
	if not ZOOM_REGION.has_point(screen_pos):
		return false
	if _find_card_under(screen_pos, null) != null:
		return false
	if hand != null:
		if bool(hand.get("input_paused")):
			return false
		if hand.has_method("has_hovered_card") and hand.has_hovered_card():
			return false
	return true

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Anchor the zoom so the world point currently rendered at screen_pos
	# stays at screen_pos after the scale change.
	var current := scale.x
	var target: float = clampf(current * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(target, current):
		return
	var ratio := target / current
	position = screen_pos + (position - screen_pos) * ratio
	scale = Vector2(target, target)

# ---------------------------------------------------------------------------
# Grid math

func _cursor_local() -> Vector2:
	return to_local(get_global_mouse_position())

static func _cell_to_local(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL_W, cell.y * CELL_H)

static func _local_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x / CELL_W), roundi(p.y / CELL_H))

func _nearest_empty_cell(local_pos: Vector2) -> Vector2i:
	# Chebyshev-ring search outward from the cell containing local_pos. Within
	# each ring sort by Euclidean distance so a side cell beats a corner —
	# matches what the cursor visually expects when sitting near an edge.
	var center := _local_to_cell(local_pos)
	for radius in range(0, 200):
		var ring: Array[Vector2i] = []
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if radius > 0 and abs(dx) != radius and abs(dy) != radius:
					continue
				var cell := center + Vector2i(dx, dy)
				if not _occupied.has(cell):
					ring.append(cell)
		if not ring.is_empty():
			ring.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
				return local_pos.distance_squared_to(_cell_to_local(a)) < local_pos.distance_squared_to(_cell_to_local(b)))
			return ring[0]
	return center

func find_empty_cell_in_view() -> Vector2i:
	# For arc-emit spawn: pick an empty cell near the screen centre. Falls back
	# to ring-search at the centre if every visible cell is taken.
	var vp := get_viewport_rect()
	var tl := to_local(vp.position)
	var br := to_local(vp.end)
	var vr := Rect2(minf(tl.x, br.x), minf(tl.y, br.y), absf(br.x - tl.x), absf(br.y - tl.y))
	if vr.size == Vector2.ZERO:
		return _nearest_empty_cell(Vector2.ZERO)
	var center := vr.get_center()
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
		return _nearest_empty_cell(center)
	candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return center.distance_squared_to(_cell_to_local(a)) < center.distance_squared_to(_cell_to_local(b)))
	return candidates[0]

# ---------------------------------------------------------------------------
# Emit-arc animations (card-back from the planet deck → settle on the board).

func emit_card_to_cell(data: CardData) -> void:
	# A new top-level entity (planet, alien ship) — flies into a free cell.
	var cell := find_empty_cell_in_view()
	var target := _cell_to_local(cell)
	var target_global := to_global(target)
	_run_arc(_planet_deck_position, target_global, _on_emit_cell_arrived.bind(data, target, cell))

func emit_card_onto_stack(data: CardData, anchor_tag: String) -> void:
	# A new card stacked onto an existing anchor (journal entries → journal).
	var anchor := find_root_with_tag(anchor_tag)
	if anchor == null:
		return
	var target_global: Vector2 = anchor.get_stack_top().global_position
	_run_arc(_planet_deck_position, target_global, _on_emit_stack_arrived.bind(data, anchor))

func _run_arc(start_global: Vector2, end_global: Vector2, on_done: Callable) -> void:
	var back: Node2D = CARD_BACK_SCENE.instantiate()
	add_child(back)
	back.global_position = start_global
	back.z_index = ZLayers.ARC_BACK
	var midpoint := (start_global + end_global) * 0.5
	var control := midpoint + Vector2(0.0, -EMIT_ARC_PEAK)
	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(_arc_back.bind(back, start_global, control, end_global), 0.0, 1.0, EMIT_DURATION)
	tween.parallel().tween_property(back, "rotation", -PI, EMIT_DURATION)
	tween.parallel().tween_property(back, "scale", Vector2(1.4, 1.4), EMIT_DURATION)
	tween.finished.connect(_on_arc_done.bind(back, on_done))

func _arc_back(t: float, back: Node2D, start: Vector2, control: Vector2, end: Vector2) -> void:
	var u := 1.0 - t
	back.global_position = u * u * start + 2.0 * u * t * control + t * t * end

func _on_arc_done(back: Node2D, on_done: Callable) -> void:
	back.queue_free()
	on_done.call()

func _on_emit_cell_arrived(data: CardData, target_local: Vector2, cell: Vector2i) -> void:
	var c := _spawn_card(data, target_local, cell)
	c.play_settle_in()

func _on_emit_stack_arrived(data: CardData, anchor: Card) -> void:
	if not is_instance_valid(anchor):
		return
	var c: Card = CARD_SCENE.instantiate()
	# Park the card on PlaySpace itself (NOT under the leaf — that would make
	# `c` the new leaf and attach_below would reparent it to itself).
	# attach_below reparents into the leaf and tweens into the new slot,
	# preserving global transform so the visual smoothly transitions.
	add_child(c)
	var leaf := anchor.get_stack_top()
	c.global_position = leaf.global_position
	c.configure(data)
	anchor.attach_below(c)
