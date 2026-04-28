class_name Card extends Node2D

signal fly_finished(card: Card)
signal showcase_done(card: Card)

const SIZE := Vector2(120, 168)
const HOVER_LIFT := 32.0
const SETTLE_SPEED := 14.0

# Logical kind of card. Drives both UI badge color and how main.gd dispatches
# the play action (BUILD_* targets a planet, DISCOVER and TRADE_ROUTE don't).
# DO NOT reorder — values are stored as ints in player_deck and in the
# data/cards/*.tres CardData resources.
enum CardType { DISCOVER, BUILD_COLONY, BUILD_FACTORY, BUILD_LAB, BUILD_POWER_PLANT, TRADE_ROUTE }

# Tinted gold border drawn on the planet currently under the cursor while a
# planet-targeting card is being dragged.
const TARGETED_BORDER := Color(1.0, 0.85, 0.2)

# Play animation: settle into the showcase point, then arc over to the discard.
# The settle phase is _process-driven (exponential ease) so it can chase a
# moving target — letting the showcase set re-spread when cards join/leave.
const FLY_SETTLE_SPEED := 9.0
const SETTLE_DURATION := 0.55
const ARC_DURATION := 0.55
const SHOWCASE_SCALE := 1.15
const FINAL_SCALE := 0.4
const ARC_PEAK_HEIGHT := 160.0
const SPIN_REVOLUTIONS := 2.0
# Bump the card's z-index when it leaves showcase so the arc renders above
# any cards still settling at the showcase line.
const ARC_Z_BUMP := 1000

const NORMAL_BG := Color(0.95, 0.92, 0.82)
const HOVER_BG := Color(1.0, 0.96, 0.86)
const PLAY_BG := Color(0.82, 0.98, 0.82)
const NORMAL_BORDER := Color(0.15, 0.12, 0.08)
const HOVER_BORDER := Color(1.0, 0.85, 0.2)
const PLAY_BORDER := Color(0.25, 0.85, 0.35)
const UNAFFORDABLE_MODULATE := Color(0.55, 0.55, 0.65)

enum State { IDLE, DRAGGING, FLYING, SETTLED_BUILDING }
enum FlyPhase { NONE, SETTLE, ARC }

@onready var _body: Panel = $Body
@onready var _name_label: Label = $Body/NameLabel
@onready var _body_label: Label = get_node_or_null("Body/NameLabel2")
@onready var _cost_icons: Control = $Body/CostIcons

# Cost-icon visuals. Each point of cost spawns one circular icon stacked
# right-to-left on top of the card. The rightmost icon is fully visible; each
# subsequent one peeks out from behind by ICON_VISIBLE_STEP pixels, creating
# a stacked-chip look that scales with cost.
const COST_ICON_DIAMETER := 26
# Anchor of the rightmost icon, in CostIcons-local coords (CostIcons spans the
# top of Body width). Right edge of the rightmost icon sits ~3px in from the
# Body's right edge.
const COST_ICON_RIGHT_X := 117
const COST_ICON_TOP_Y := 0
# How much of each new icon is visible past the one in front of it.
const ICON_VISIBLE_STEP := 11

var card_name: String = "Strike":
	set(value):
		card_name = value
		if is_node_ready():
			_name_label.text = value

var cost: int = 1:
	set(value):
		cost = value
		if is_node_ready():
			_rebuild_cost_icons()

# Which resource the cost is paid from. "credits" for most cards, "research"
# for trade routes. Used to build the cost dict passed to GameState.can_afford().
var cost_resource: String = "credits"

# Logical card kind — see CardType enum. Trade Route and Discover use the
# threshold-release flow; the BUILD_* variants drag-onto-planet instead.
var card_type: int = CardType.DISCOVER

# Whether release-to-play means "drop on a planet" vs. "release above hand
# threshold". Hand consults this in _process to drive planet hover highlighting
# and in _end_drag to dispatch the right code path.
var targets_planet: bool = false

# Body description text — second line on the card. Set per card kind.
var body_text: String = "":
	set(value):
		body_text = value
		if is_node_ready() and _body_label != null:
			_body_label.text = value

var hovered: bool = false
var play_ready: bool = false
var affordable: bool = true
var rest_position: Vector2 = Vector2.ZERO
var rest_rotation: float = 0.0

var _state: int = State.IDLE
var _fly_phase: int = FlyPhase.NONE
var _settle_timer: float = 0.0
var _showcase_target_local: Vector2 = Vector2.ZERO
var _fly_tween: Tween = null
var _body_stylebox: StyleBoxFlat = null

# Quadratic bezier endpoints for the arc-to-discard phase.
var _arc_start: Vector2 = Vector2.ZERO
var _arc_control: Vector2 = Vector2.ZERO
var _arc_end: Vector2 = Vector2.ZERO

func _ready() -> void:
	# Per-card duplicate so hover highlighting on one card doesn't bleed to others.
	_body_stylebox = (_body.get_theme_stylebox("panel") as StyleBoxFlat).duplicate()
	_body.add_theme_stylebox_override("panel", _body_stylebox)
	_name_label.text = card_name
	if _body_label != null:
		_body_label.text = body_text
	_rebuild_cost_icons()
	_refresh_visual()

func cost_dict() -> Dictionary:
	# Convenience for GameState.can_afford / deduct.
	return { cost_resource: cost }

func _cost_icon_colors() -> Array:
	# (bg, border) for the resource the cost is paid from. Fill colors mirror
	# the HUD label colors so the cost reads as the same resource at a glance:
	#   Credits  → soft gold     (matches HUD "Credits"  label)
	#   Research → light lavender (matches HUD "Research" label)
	# Borders are a deep version of the same hue for contrast on the
	# cream-colored card body.
	if cost_resource == "research":
		return [Color(0.85, 0.7, 1.0), Color(0.3, 0.15, 0.5)]
	return [Color(1.0, 0.95, 0.6), Color(0.5, 0.4, 0.05)]

func _rebuild_cost_icons() -> void:
	# Spawn one circular pip per point of `cost`, stacked right-to-left and
	# slightly behind each other (rightmost on top). Cost 0 → no icons.
	if _cost_icons == null:
		return
	for c in _cost_icons.get_children():
		c.queue_free()
	if cost <= 0:
		return
	var colors := _cost_icon_colors()
	var bg: Color = colors[0]
	var border: Color = colors[1]
	# Add deepest-back icon first so child order matches draw order: later
	# children render on top, so the rightmost icon (i = 0 here) ends up last
	# and on top of the stack.
	for i in range(cost - 1, -1, -1):
		var pip := Panel.new()
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.size = Vector2(COST_ICON_DIAMETER, COST_ICON_DIAMETER)
		# i = 0 is rightmost; higher i sits further left and behind.
		pip.position = Vector2(
			COST_ICON_RIGHT_X - COST_ICON_DIAMETER - i * ICON_VISIBLE_STEP,
			COST_ICON_TOP_Y)
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.border_color = border
		sb.border_width_left = 2
		sb.border_width_top = 2
		sb.border_width_right = 2
		sb.border_width_bottom = 2
		var radius: int = COST_ICON_DIAMETER / 2
		sb.corner_radius_top_left = radius
		sb.corner_radius_top_right = radius
		sb.corner_radius_bottom_left = radius
		sb.corner_radius_bottom_right = radius
		pip.add_theme_stylebox_override("panel", sb)
		_cost_icons.add_child(pip)

func set_rest(pos: Vector2, rot: float) -> void:
	rest_position = pos
	rest_rotation = rot

func set_hovered(value: bool) -> void:
	if hovered == value:
		return
	hovered = value
	_refresh_visual()

func set_play_ready(value: bool) -> void:
	if play_ready == value:
		return
	play_ready = value
	_refresh_visual()

func set_affordable(value: bool) -> void:
	if affordable == value:
		return
	affordable = value
	_refresh_visual()

func configure(p_name: String, p_type: int, p_cost: int, p_resource: String, p_body: String) -> void:
	# Bulk setter so main.gd can spawn cards with one call from a definition dict.
	card_name = p_name
	card_type = p_type
	# Set resource before cost so the cost setter, which rebuilds icons, picks
	# up the correct color the first time.
	cost_resource = p_resource
	cost = p_cost
	body_text = p_body
	targets_planet = (p_type == CardType.BUILD_COLONY \
		or p_type == CardType.BUILD_FACTORY \
		or p_type == CardType.BUILD_LAB \
		or p_type == CardType.BUILD_POWER_PLANT)
	if is_node_ready():
		_rebuild_cost_icons()

func _refresh_visual() -> void:
	if _body_stylebox == null:
		return
	# play_ready takes precedence — it only applies during drag, when hover is off anyway.
	if play_ready:
		_body_stylebox.bg_color = PLAY_BG
		_body_stylebox.border_color = PLAY_BORDER
	elif hovered:
		_body_stylebox.bg_color = HOVER_BG
		_body_stylebox.border_color = HOVER_BORDER
	else:
		_body_stylebox.bg_color = NORMAL_BG
		_body_stylebox.border_color = NORMAL_BORDER
	# Unaffordable cards desaturate via modulate so the gray tint applies on top
	# of whichever stylebox is active above.
	modulate = Color.WHITE if affordable else UNAFFORDABLE_MODULATE

func start_drag() -> void:
	_kill_fly_tween()
	_state = State.DRAGGING
	set_play_ready(false)

func update_drag_position(world_pos: Vector2) -> void:
	if _state != State.DRAGGING:
		return
	var parent := get_parent() as Node2D
	position = parent.to_local(world_pos) if parent != null else world_pos

func end_drag_return() -> void:
	# Back to IDLE; _process eases toward rest pose.
	set_play_ready(false)
	_state = State.IDLE

func end_drag_fly(target_world_pos: Vector2, showcase_world_pos: Vector2) -> void:
	_state = State.FLYING
	set_play_ready(false)
	_arc_end = _to_parent_local(target_world_pos)
	_showcase_target_local = _to_parent_local(showcase_world_pos)
	_fly_phase = FlyPhase.SETTLE
	_settle_timer = SETTLE_DURATION

func settle_into_building_slot(local_target: Vector2, target_scale: Vector2) -> void:
	# The card itself becomes the building visual on a planet. Caller has
	# already reparented this card into the planet's building container, so
	# `local_target` is in that container's local coordinates. The tween
	# eases position/scale/rotation into place and the card stays there
	# permanently — no fade-out, no queue_free.
	_kill_fly_tween()
	_state = State.SETTLED_BUILDING
	set_play_ready(false)
	set_hovered(false)
	# Sit at z=0 so neighbours stack predictably (scene-tree order decides
	# which card draws on top — controlled by the planet card).
	z_index = 0
	var dur := 0.45
	_fly_tween = create_tween().set_parallel(true)
	_fly_tween.tween_property(self, "position", local_target, dur) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_fly_tween.tween_property(self, "scale", target_scale, dur) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_fly_tween.tween_property(self, "rotation", 0.0, dur)

func discard_fly(target_world_pos: Vector2) -> void:
	# Skip the showcase phase — go straight into the arc. Used for end-of-turn
	# cleanup where we just want the cards swept off the board. Drop z to 0 so
	# this card renders below freshly-drawn cards in the new hand
	# (which sit at Hand.HAND_Z_BASE..+n-1).
	_state = State.FLYING
	_arc_end = _to_parent_local(target_world_pos)
	set_play_ready(false)
	set_hovered(false)
	z_index = 0
	_start_arc_phase(false)

func update_showcase_target(world_pos: Vector2) -> void:
	# Only meaningful while the card is still settling at the showcase point;
	# once the arc has begun, the bezier path is locked in.
	if _fly_phase != FlyPhase.SETTLE:
		return
	_showcase_target_local = _to_parent_local(world_pos)

func _to_parent_local(world_pos: Vector2) -> Vector2:
	var parent := get_parent() as Node2D
	return parent.to_local(world_pos) if parent != null else world_pos

func _start_arc_phase(elevate_z: bool = true) -> void:
	_fly_phase = FlyPhase.ARC
	if elevate_z:
		# Played cards need to render above the rest of the hand during their
		# arc (they're the focus). End-turn discards skip this so newly-drawn
		# cards in the same hand-z range can render in front.
		z_index += ARC_Z_BUMP
	# Let listeners know this card is leaving the showcase set so they can
	# squeeze the remaining cards together.
	showcase_done.emit(self)

	# Bezier setup: arc upward from current position to the discard target.
	_arc_start = position
	var midpoint := (_arc_start + _arc_end) * 0.5
	_arc_control = midpoint + Vector2(0.0, -ARC_PEAK_HEIGHT)

	# Spin in the direction of travel; relative to current rotation so a slight
	# residual tilt from settle doesn't break the revolution count.
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

func _process(delta: float) -> void:
	var t := 1.0 - exp(-delta * SETTLE_SPEED)
	if _state == State.IDLE:
		var target_pos := rest_position
		var target_rot := rest_rotation
		if hovered:
			target_pos += Vector2.UP.rotated(rest_rotation) * HOVER_LIFT
		position = position.lerp(target_pos, t)
		rotation = lerp_angle(rotation, target_rot, t)
	elif _state == State.DRAGGING:
		rotation = lerp_angle(rotation, 0.0, t)
	elif _state == State.FLYING and _fly_phase == FlyPhase.SETTLE:
		var settle_t := 1.0 - exp(-delta * FLY_SETTLE_SPEED)
		position = position.lerp(_showcase_target_local, settle_t)
		rotation = lerp_angle(rotation, 0.0, settle_t)
		scale = scale.lerp(Vector2.ONE * SHOWCASE_SCALE, settle_t)
		_settle_timer -= delta
		if _settle_timer <= 0.0:
			_start_arc_phase()
