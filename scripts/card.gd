class_name Card extends Node2D

# A single card. Renders one of two visual variants based on its tags:
# - "world" cards (planet / journal / alien_ship): dark body, optional sphere
#   for actual planets, type label, white name. These are the anchors that
#   sit in play-space cells and accept stacks of other cards.
# - "play" cards: parchment body with a name + body-text panel. Cards in the
#   player's hand and stacked buildings on the board.
#
# Stacks are scene-tree parent-chains. The top of the stack is a child of the
# play space's `Stacks` container; each successive card is a child of the
# previous, positioned at (0, _step) so the next card peeks out below by _step
# pixels. Dragging the chain root moves the whole subtree because Godot's
# transform inherits down the tree.
#
# Drag input on the board is owned by `PlaySpace`, not by Card. The hand-drag
# flow keeps its existing api (start_drag/update_drag_position/end_drag_return)
# since hand cards live under the Hand node.

signal fly_finished(card: Card)
signal showcase_done(card: Card)

const SIZE := Vector2(120, 168)
const HOVER_LIFT := 32.0
const SETTLE_SPEED := 14.0

# Pile-fly animation (release-to-discard, end-of-turn discard).
const FLY_SETTLE_SPEED := 9.0
const SETTLE_DURATION := 0.55
const ARC_DURATION := 0.55
const SHOWCASE_SCALE := 1.15
const FINAL_SCALE := 0.4
const ARC_PEAK_HEIGHT := 160.0
const SPIN_REVOLUTIONS := 2.0

# Stack peek geometry. Each stacked card sits at (0, _step) in its parent's
# frame, so as the chain descends each card's body covers all but a _step-tall
# strip of the card above it. Hover expands _step *only on the child of the
# hovered card* so that one card reveals more of itself; everyone else holds
# STEP_COLLAPSED. The cards below the expanded slot are pushed down by the
# extra peek as a side-effect of inherited transforms.
const STEP_COLLAPSED := 8.0
const STEP_EXPANDED := 28.0
const STEP_TWEEN_DURATION := 0.18

# Settle-into-board animation when arriving fresh on the play space.
const SETTLE_IN_FROM := Vector2(0.3, 0.3)
const SETTLE_IN_DURATION := 0.3

# Attach-to-stack animation when dropped on a target.
const ATTACH_DURATION := 0.1

# Color schemes. Play cards are parchment; world cards (planets/journal/ship)
# are tinted dark.
const PLAY_BG := Color(0.95, 0.92, 0.82)
const PLAY_HOVER_BG := Color(1.0, 0.96, 0.86)
const PLAY_READY_BG := Color(0.82, 0.98, 0.82)
const PLAY_BORDER := Color(0.15, 0.12, 0.08)
const PLAY_HOVER_BORDER := Color(1.0, 0.85, 0.2)
const PLAY_READY_BORDER := Color(0.25, 0.85, 0.35)

const WORLD_BG := Color(0.18, 0.22, 0.32)
const WORLD_BORDER := Color(0.4, 0.45, 0.55)
const WORLD_HOVER_BORDER := Color(0.85, 0.9, 1.0)
const WORLD_TARGET_BORDER := Color(1.0, 0.85, 0.2)
const WORLD_BORDER_W_NORMAL := 0
const WORLD_BORDER_W_HOVER := 4
const WORLD_BORDER_W_TARGET := 5
const PLAY_BORDER_W_NORMAL := 1
const PLAY_BORDER_W_HOVER := 2
const PLAY_BORDER_W_READY := 2

# Per-type planet sphere & body tints. Multi-type strings ("Ice/Oceanic") are
# averaged across components so the visual reads in-between.
const TYPE_COLORS := {
	"Rocky": Color(0.55, 0.42, 0.30),
	"Oceanic": Color(0.20, 0.45, 0.85),
	"Ice": Color(0.78, 0.92, 1.00),
	"Gas Giant": Color(0.88, 0.66, 0.38),
	"Journal": Color(0.32, 0.26, 0.18),
	"Ship": Color(0.55, 0.20, 0.55),
}
const FALLBACK_TYPE_COLOR := Color(0.5, 0.5, 0.5)

# Auto-shrink the name/body labels if their text gets long.
const NAME_FONT_SIZES := [[12, 18], [14, 16], [999, 14]]
const BODY_FONT_SIZES := [[25, 13], [40, 12], [999, 11]]

enum State { IDLE_HAND, IDLE_BOARD, DRAGGING_HAND, FLYING }
enum FlyPhase { NONE, SETTLE, ARC }

@onready var _body: Panel = $Body
@onready var _name_label: Label = $Body/NameLabel
@onready var _type_label: Label = $Body/TypeLabel
@onready var _sphere: ColorRect = $Body/Sphere
@onready var _body_label: Label = $Body/BodyLabel

# Card data
var data: CardData = null
var card_types: Array[String] = []
var can_stack: Array[String] = []
var releases_on_threshold: bool = false

# Runtime state. Used by ageing for buildings (see main._age_buildings).
var turns_alive: int = 0

# Visual state
var hovered: bool = false
var targeted: bool = false
var play_ready: bool = false

# Hand-drag state (only meaningful while in Hand).
var rest_position: Vector2 = Vector2.ZERO
var rest_rotation: float = 0.0
var _state: int = State.IDLE_HAND

# Board-cell tag (only meaningful when this card is the chain root of a stack
# living in PlaySpace.Stacks). PlaySpace owns the cell↔root bookkeeping.
var grid_cell: Vector2i = Vector2i.ZERO

# Pile-fly state.
var _fly_phase: int = FlyPhase.NONE
var _settle_timer: float = 0.0
var _showcase_target_local: Vector2 = Vector2.ZERO
var _fly_tween: Tween = null
var _arc_start: Vector2 = Vector2.ZERO
var _arc_control: Vector2 = Vector2.ZERO
var _arc_end: Vector2 = Vector2.ZERO

# Per-instance duplicates so visual changes don't bleed across cards.
var _body_stylebox: StyleBoxFlat = null
var _body_label_settings: LabelSettings = null

# Stack peek. Stored on every card — represents this card's offset from its
# parent in the chain. Per-card so a single child can be expanded while its
# siblings stay collapsed (only meaningful for non-root cards; the root has
# no chain parent and its _step is unused).
var _step: float = STEP_COLLAPSED
var _step_tween: Tween = null

# Only meaningful on the chain root. Points at whichever card in this chain
# is currently being hovered, or null when nothing is. The child of this
# card gets STEP_EXPANDED; everyone else gets STEP_COLLAPSED.
var _hover_card_in_chain: Card = null

# Snapshot of (card, start_step, target_step) tuples driven by the per-card
# hover-step tween (_animate_chain_layout). Held on the chain root.
var _pending_chain_entries: Array = []

# True while attach_below is animating this card into its slot. The chain
# layout writers skip the position write for attaching cards so the hover-
# expansion tween doesn't fight the attach tween.
var _attaching: bool = false
var _attach_start_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	_body_stylebox = (_body.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
	_body.add_theme_stylebox_override("panel", _body_stylebox)
	if _body_label != null and _body_label.label_settings != null:
		_body_label_settings = _body_label.label_settings.duplicate()
		_body_label.label_settings = _body_label_settings
	if _sphere != null and _sphere.material != null:
		_sphere.material = _sphere.material.duplicate()
	if data != null:
		_apply_data_visuals()
	_refresh_visual()

func configure(p_data: CardData) -> void:
	data = p_data
	card_types = p_data.card_types.duplicate()
	can_stack = p_data.can_stack.duplicate()
	releases_on_threshold = p_data.releases_on_threshold
	if is_node_ready():
		_apply_data_visuals()
		_refresh_visual()

func is_world_card() -> bool:
	return ("planet" in card_types) or ("journal" in card_types) or ("alien_ship" in card_types)

func _apply_data_visuals() -> void:
	if data == null:
		return
	var is_planet := "planet" in card_types
	var is_journal := "journal" in card_types
	var is_ship := "alien_ship" in card_types
	var world_kind := is_planet or is_journal or is_ship

	_name_label.text = data.card_name
	_name_label.add_theme_font_size_override("font_size", _font_size_for(data.card_name.length(), NAME_FONT_SIZES))
	_name_label.add_theme_color_override("font_color", Color(1, 1, 1) if world_kind else Color(0.1, 0.08, 0.05))

	_sphere.visible = is_planet
	_type_label.visible = is_planet
	if is_planet:
		_type_label.text = data.planet_type
		var color := _color_for_type(data.planet_type)
		_apply_sphere_color(color)
		_apply_world_body_color(color)
	elif is_journal:
		_apply_world_body_color(TYPE_COLORS["Journal"])
	elif is_ship:
		_apply_world_body_color(TYPE_COLORS["Ship"])

	_body_label.visible = not world_kind
	if not world_kind:
		_body_label.text = data.body
		if _body_label_settings != null:
			_body_label_settings.font_size = _font_size_for(data.body.length(), BODY_FONT_SIZES)
		# Reset to play-card body color (in case this card was previously a
		# world card and got tinted dark). Refresh_visual will pick the right
		# bg/border for the current state.
		_body_stylebox.bg_color = PLAY_BG

static func _font_size_for(length: int, table: Array) -> int:
	for entry in table:
		if length <= entry[0]:
			return entry[1]
	return table[-1][1]

func _color_for_type(type_string: String) -> Color:
	var parts: Array = []
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

func _apply_sphere_color(color: Color) -> void:
	var mat: ShaderMaterial = _sphere.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("base_color", color)

func _apply_world_body_color(type_color: Color) -> void:
	# Tint toward WORLD_BG so the white name label stays readable.
	var t := 0.55
	_body_stylebox.bg_color = Color(
		lerp(type_color.r, WORLD_BG.r, t),
		lerp(type_color.g, WORLD_BG.g, t),
		lerp(type_color.b, WORLD_BG.b, t),
		1.0)

# ---------------------------------------------------------------------------
# Visual state setters

func set_hovered(value: bool) -> void:
	# Pure visual border/bg refresh. Chain-step expansion is driven separately
	# by PlaySpace via set_chain_hover_target on the chain root, since the
	# hovered card may be any depth within the chain (not just the root).
	if hovered == value:
		return
	hovered = value
	_refresh_visual()

func set_targeted(value: bool) -> void:
	if targeted == value:
		return
	targeted = value
	_refresh_visual()

func set_play_ready(value: bool) -> void:
	if play_ready == value:
		return
	play_ready = value
	_refresh_visual()

func _refresh_visual() -> void:
	if _body_stylebox == null:
		return
	var w: int = 0
	if is_world_card():
		if targeted:
			_body_stylebox.border_color = WORLD_TARGET_BORDER
			w = WORLD_BORDER_W_TARGET
		elif hovered:
			_body_stylebox.border_color = WORLD_HOVER_BORDER
			w = WORLD_BORDER_W_HOVER
		else:
			_body_stylebox.border_color = WORLD_BORDER
			w = WORLD_BORDER_W_NORMAL
	else:
		if play_ready:
			_body_stylebox.bg_color = PLAY_READY_BG
			_body_stylebox.border_color = PLAY_READY_BORDER
			w = PLAY_BORDER_W_READY
		elif hovered:
			_body_stylebox.bg_color = PLAY_HOVER_BG
			_body_stylebox.border_color = PLAY_HOVER_BORDER
			w = PLAY_BORDER_W_HOVER
		else:
			_body_stylebox.bg_color = PLAY_BG
			_body_stylebox.border_color = PLAY_BORDER
			w = PLAY_BORDER_W_NORMAL
	_body_stylebox.border_width_left = w
	_body_stylebox.border_width_top = w
	_body_stylebox.border_width_right = w
	_body_stylebox.border_width_bottom = w

# ---------------------------------------------------------------------------
# Stack chain (parent-child along the scene tree; Card-with-Card-children).

func get_chain_root() -> Card:
	# Walk up parents until we find one that isn't a Card; that ancestor is the
	# Stacks container and the current node is the chain root.
	var n: Card = self
	while n.get_parent() is Card:
		n = n.get_parent() as Card
	return n

func get_stack_top() -> Card:
	# The chain leaf — deepest descendant down the chain. New cards attach here.
	var n: Card = self
	var c := Card.next_chain_child(n)
	while c != null:
		n = c
		c = Card.next_chain_child(n)
	return n

static func next_chain_child(c: Card) -> Card:
	# A card can have non-Card children (Body etc.) — walk children for the
	# first Card child, which is the next link in the stack chain.
	for child in c.get_children():
		if child is Card:
			return child
	return null

static func disable_input_subtree(node: Node) -> void:
	# Make a card display-only by passing all mouse events through every
	# Control in its subtree. Used by the pile viewer and draft modal so a
	# transparent slot behind each card receives the click.
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		disable_input_subtree(child)

func get_stack_top_card_types() -> Array:
	return get_stack_top().card_types

func can_accept_stack(p_can_stack: Array) -> bool:
	# True iff the chain leaf's card_types contains every tag the dragged card
	# requires. Empty p_can_stack matches anything.
	var top: Array = get_stack_top_card_types()
	for tag in p_can_stack:
		if not (tag in top):
			return false
	return true

func attach_below(other: Card) -> void:
	# Reparent `other` (with its full subtree) under this stack's leaf at the
	# next peek slot. Tweens position/scale/rotation so drops don't snap.
	var leaf := get_stack_top()
	var root := get_chain_root()
	# reparent() preserves global transform, so the visual doesn't jump.
	if other.get_parent() != leaf:
		other.reparent(leaf)
	other.set_play_ready(false)
	other.set_hovered(false)
	other.set_targeted(false)
	other._state = State.IDLE_BOARD
	# Children inherit z relative to parent (z_as_relative=true), so this
	# offset cascades down the chain — newer-on-top for free.
	other.z_index = ZLayers.STACK_CHILD_OFFSET
	other._kill_step_tween()
	other._step = root._target_step_for_child(other)
	# Mark as attaching so the chain-layout writers (driven by hover changes
	# on the chain root) don't overwrite our in-flight position.
	other._attaching = true
	other._attach_start_pos = other.position
	var t := other.create_tween().set_parallel(true)
	# Target is recomputed each frame from the chain root's live hover state,
	# so if hover changes mid-attach we slide to the new slot.
	t.tween_method(other._update_attach_position, 0.0, 1.0, ATTACH_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(other, "scale", Vector2.ONE, ATTACH_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(other, "rotation", 0.0, ATTACH_DURATION)
	t.finished.connect(other._on_attach_done)
	# Re-snap chain layout in case `other` brought a subtree with stale
	# offsets. (Skips `other` itself while _attaching.)
	root._snap_chain_layout()

func _update_attach_position(t: float) -> void:
	var target := Vector2(0.0, get_chain_root()._target_step_for_child(self))
	position = _attach_start_pos.lerp(target, t)

func _on_attach_done() -> void:
	_attaching = false
	position = Vector2(0.0, get_chain_root()._target_step_for_child(self))

# ---------------------------------------------------------------------------
# Per-card chain layout (called on the chain root only).
#
# The chain root tracks `_hover_card_in_chain` — the single card the cursor
# is currently over. The card directly below it in the chain takes
# STEP_EXPANDED (so the hovered card reveals more of its body); every other
# child→parent gap stays at STEP_COLLAPSED. Cards below the expanded slot
# are pushed down rigidly via inherited transforms — they don't themselves
# expand. PlaySpace calls set_chain_hover_target whenever the card under
# the cursor changes; null collapses the whole chain.
#
# Hit testing in PlaySpace compensates for the visual shift: descendants of
# the hovered card keep their collapsed-position pick areas, so the player's
# cursor only has to travel STEP_COLLAPSED to move hover to the next card.

func set_chain_hover_target(card: Card) -> void:
	if _hover_card_in_chain == card:
		return
	_hover_card_in_chain = card
	_animate_chain_layout()

func _target_step_for_child(child_card: Card) -> float:
	# Called on the chain root. Returns the step `child_card` should sit at
	# from its parent — STEP_EXPANDED iff its parent is the currently-hovered
	# card in this chain.
	var parent := child_card.get_parent() as Card
	if parent != null and parent == _hover_card_in_chain:
		return STEP_EXPANDED
	return STEP_COLLAPSED

func _snap_chain_layout() -> void:
	# Instantly set every descendant to its target step. Used when a snap is
	# preferred over a tween (drag begin, post-attach re-sync). Cards mid-
	# attach own their position via the attach tween — skip the write so the
	# two animations don't fight (their _step is still updated so the attach
	# tween's destination is correct).
	_kill_step_tween()
	var c := Card.next_chain_child(self)
	while c != null:
		var target := _target_step_for_child(c)
		c._step = target
		if not c._attaching:
			c.position = Vector2(0.0, target)
		c = Card.next_chain_child(c)

func _animate_chain_layout() -> void:
	# Tween every descendant from its current step toward its target step.
	# Each card has its own start/target so a previously-expanded slot can
	# collapse while a new slot expands in the same tween.
	_kill_step_tween()
	var entries: Array = []
	var c := Card.next_chain_child(self)
	while c != null:
		entries.append([c, c._step, _target_step_for_child(c)])
		c = Card.next_chain_child(c)
	_pending_chain_entries = entries
	_step_tween = create_tween()
	_step_tween.tween_method(_apply_chain_step_progress, 0.0, 1.0, STEP_TWEEN_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _apply_chain_step_progress(t: float) -> void:
	for e in _pending_chain_entries:
		var card_node: Card = e[0]
		if not is_instance_valid(card_node):
			continue
		var start: float = e[1]
		var target: float = e[2]
		var v: float = lerp(start, target, t)
		card_node._step = v
		if not card_node._attaching:
			card_node.position = Vector2(0.0, v)

func _kill_step_tween() -> void:
	if _step_tween != null and _step_tween.is_valid():
		_step_tween.kill()
	_step_tween = null

# ---------------------------------------------------------------------------
# Hit testing

func contains_point_world(world_point: Vector2) -> bool:
	# Body-rect hit test in world coords. The card body is centred on this
	# Card node and is fixed at SIZE — the stack peek of children belongs to
	# the children, not to this card.
	var local := to_local(world_point)
	var rect := Rect2(-SIZE * 0.5, SIZE)
	return rect.has_point(local)

# ---------------------------------------------------------------------------
# Hand-drag flow (Hand still owns input for hand cards).

func set_rest(pos: Vector2, rot: float) -> void:
	rest_position = pos
	rest_rotation = rot

func start_drag() -> void:
	_kill_fly_tween()
	_state = State.DRAGGING_HAND
	set_play_ready(false)

func update_drag_position(world_pos: Vector2) -> void:
	if _state != State.DRAGGING_HAND:
		return
	var parent := get_parent() as Node2D
	position = parent.to_local(world_pos) if parent != null else world_pos

func end_drag_return() -> void:
	set_play_ready(false)
	_state = State.IDLE_HAND

# ---------------------------------------------------------------------------
# Pile-fly animation (release-to-discard, end-of-turn discard).

func end_drag_fly(target_world_pos: Vector2, showcase_world_pos: Vector2) -> void:
	_state = State.FLYING
	set_play_ready(false)
	_arc_end = _to_parent_local(target_world_pos)
	_showcase_target_local = _to_parent_local(showcase_world_pos)
	_fly_phase = FlyPhase.SETTLE
	_settle_timer = SETTLE_DURATION

func discard_fly(target_world_pos: Vector2) -> void:
	# Skip the showcase phase — straight into the arc.
	_state = State.FLYING
	_arc_end = _to_parent_local(target_world_pos)
	set_play_ready(false)
	set_hovered(false)
	z_index = 0
	_start_arc_phase(false)

func update_showcase_target(world_pos: Vector2) -> void:
	if _fly_phase != FlyPhase.SETTLE:
		return
	_showcase_target_local = _to_parent_local(world_pos)

func _to_parent_local(world_pos: Vector2) -> Vector2:
	var parent := get_parent() as Node2D
	return parent.to_local(world_pos) if parent != null else world_pos

func _start_arc_phase(elevate_z: bool = true) -> void:
	_fly_phase = FlyPhase.ARC
	if elevate_z:
		# Clamp against Godot's z cap — set_z_index rejects values outside
		# ±4096, so an unclamped bump would silently no-op for a card flying
		# straight from a high drag z.
		z_index = mini(z_index + ZLayers.ARC_BUMP, ZLayers.GODOT_Z_CAP)
	showcase_done.emit(self)
	_arc_start = position
	var midpoint := (_arc_start + _arc_end) * 0.5
	_arc_control = midpoint + Vector2(0.0, -ARC_PEAK_HEIGHT)
	var spin_direction := signf(_arc_end.x - _arc_start.x)
	if spin_direction == 0.0:
		spin_direction = 1.0
	var spin_target := rotation + TAU * SPIN_REVOLUTIONS * spin_direction
	_fly_tween = create_tween()
	_fly_tween.set_ease(Tween.EASE_IN)
	_fly_tween.set_trans(Tween.TRANS_QUAD)
	_fly_tween.tween_method(_arc_position, 0.0, 1.0, ARC_DURATION)
	_fly_tween.parallel().tween_property(self, "rotation", spin_target, ARC_DURATION)
	_fly_tween.parallel().tween_property(self, "scale", Vector2.ONE * FINAL_SCALE, ARC_DURATION)
	_fly_tween.finished.connect(_on_fly_done)

func _arc_position(t: float) -> void:
	var u := 1.0 - t
	position = u * u * _arc_start + 2.0 * u * t * _arc_control + t * t * _arc_end

func _on_fly_done() -> void:
	_fly_tween = null
	fly_finished.emit(self)

func _kill_fly_tween() -> void:
	if _fly_tween != null and _fly_tween.is_valid():
		_fly_tween.kill()
	_fly_tween = null

# ---------------------------------------------------------------------------
# Settle-in animation when this card first appears on the play space.

func play_settle_in() -> void:
	scale = SETTLE_IN_FROM
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT)
	t.set_trans(Tween.TRANS_BACK)
	t.tween_property(self, "scale", Vector2.ONE, SETTLE_IN_DURATION)

# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var t := 1.0 - exp(-delta * SETTLE_SPEED)
	if _state == State.IDLE_HAND:
		var target_pos := rest_position
		var target_rot := rest_rotation
		if hovered:
			target_pos += Vector2.UP.rotated(rest_rotation) * HOVER_LIFT
		position = position.lerp(target_pos, t)
		rotation = lerp_angle(rotation, target_rot, t)
	elif _state == State.DRAGGING_HAND:
		rotation = lerp_angle(rotation, 0.0, t)
	elif _state == State.FLYING and _fly_phase == FlyPhase.SETTLE:
		var settle_t := 1.0 - exp(-delta * FLY_SETTLE_SPEED)
		position = position.lerp(_showcase_target_local, settle_t)
		rotation = lerp_angle(rotation, 0.0, settle_t)
		scale = scale.lerp(Vector2.ONE * SHOWCASE_SCALE, settle_t)
		_settle_timer -= delta
		if _settle_timer <= 0.0:
			_start_arc_phase()

# ---------------------------------------------------------------------------
# Entered-board API: caller (PlaySpace) flips state when this card has been
# placed/snapped into a cell or attached to a stack.

func set_state_idle_board() -> void:
	_state = State.IDLE_BOARD
	set_play_ready(false)
	set_hovered(false)
	set_targeted(false)
