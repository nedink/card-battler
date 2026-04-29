class_name Card extends Node2D

signal fly_finished(card: Card)
signal showcase_done(card: Card)

const SIZE := Vector2(120, 168)
const HOVER_LIFT := 32.0
const SETTLE_SPEED := 14.0

# Tinted gold border drawn on the planet currently under the cursor while a
# stack-targeting card is being dragged.
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

const NEUTRAL_BG := Color(0.95, 0.92, 0.82)
const NEUTRAL_HOVER_BG := Color(1.0, 0.96, 0.86)
const PLAY_BG := Color(0.82, 0.98, 0.82)
const NORMAL_BORDER := Color(0.15, 0.12, 0.08)
const HOVER_BORDER := Color(1.0, 0.85, 0.2)
const PLAY_BORDER := Color(0.25, 0.85, 0.35)

enum State { IDLE, DRAGGING, FLYING, SETTLED_BUILDING }
enum FlyPhase { NONE, SETTLE, ARC }

@onready var _body: Panel = $Body
@onready var _name_label: Label = $Body/NameLabel
@onready var _body_label: Label = get_node_or_null("Body/NameLabel2")

# Shrink text based on character count. Each row is [max_chars, font_size];
# the first row whose max_chars >= length wins. The last row's max_chars is
# effectively the floor (anything longer uses its size).
const NAME_FONT_SIZES := [[12, 18], [14, 16], [999, 14]]
const BODY_FONT_SIZES := [[25, 13], [40, 12], [999, 11]]

var _body_label_settings: LabelSettings = null

var card_name: String = "Strike":
	set(value):
		card_name = value
		if is_node_ready():
			_name_label.text = value
			_name_label.add_theme_font_size_override("font_size", _font_size_for(value.length(), NAME_FONT_SIZES))

# Source CardData resource — populated by configure(). Acts as the card's
# identity for dispatch and pile-storage; everything else (name, tags, body)
# is derived from it.
var data: CardData = null

# Tags identifying this card (mirrored from data.card_types for fast access).
var card_types: Array[String] = []

# Tags the top of a target stack must contain for this card to stack on it.
var can_stack: Array[String] = []

# When true, the card plays via release-above-threshold instead of by being
# dragged onto a stack. Hand consults this in _process to gate planet
# highlighting and in _end_drag to dispatch the right code path.
var releases_on_threshold: bool = false

# Body description text — second line on the card. Set per card kind.
var body_text: String = "":
	set(value):
		body_text = value
		if is_node_ready() and _body_label != null:
			_body_label.text = value
			_body_label_settings.font_size = _font_size_for(value.length(), BODY_FONT_SIZES)

var hovered: bool = false
var play_ready: bool = false
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
	_name_label.add_theme_font_size_override("font_size", _font_size_for(card_name.length(), NAME_FONT_SIZES))
	if _body_label != null:
		# Duplicate so per-card font_size changes don't leak into other cards.
		_body_label_settings = _body_label.label_settings.duplicate()
		_body_label.label_settings = _body_label_settings
		_body_label.text = body_text
		_body_label_settings.font_size = _font_size_for(body_text.length(), BODY_FONT_SIZES)
	_refresh_visual()

static func _font_size_for(length: int, table: Array) -> int:
	for entry in table:
		if length <= entry[0]:
			return entry[1]
	return table[-1][1]

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

func configure(p_data: CardData) -> void:
	# Bulk setter so main.gd can spawn cards with one call from a CardData ref.
	data = p_data
	card_name = p_data.card_name
	body_text = p_data.body
	card_types = p_data.card_types.duplicate()
	can_stack = p_data.can_stack.duplicate()
	releases_on_threshold = p_data.releases_on_threshold

func _refresh_visual() -> void:
	if _body_stylebox == null:
		return
	# play_ready takes precedence — it only applies during drag, when hover is off anyway.
	if play_ready:
		_body_stylebox.bg_color = PLAY_BG
		_body_stylebox.border_color = PLAY_BORDER
	elif hovered:
		_body_stylebox.bg_color = NEUTRAL_HOVER_BG
		_body_stylebox.border_color = HOVER_BORDER
	else:
		_body_stylebox.bg_color = NEUTRAL_BG
		_body_stylebox.border_color = NORMAL_BORDER

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
