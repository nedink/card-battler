extends Node

# Draft autoload — reusable "pick N from a pack" UI flow.
#
# Callers post requests via `request(pool, pack_size, on_picked)`. Each request
# samples `pack_size` random cards from `pool` (without replacement), shows a
# modal that lets the player click one, then calls `on_picked(chosen)` with the
# selected CardData. Requests are serialised through a FIFO queue, so multiple
# triggers in the same frame queue up and the player resolves them one by one.
#
# Signals:
#   started  — emitted when the modal becomes visible. Use to pause game input.
#   finished — emitted after the last pending request resolves (queue empty).
#
# This is a minimal implementation: pick_count is fixed at 1, no skip button,
# no animations beyond a fade-in. All of those can be added without touching
# call sites.

signal started
signal finished

const MODAL_SCENE: PackedScene = preload("res://scenes/draft_modal.tscn")

# Sentinel returned/passed when no arc target was supplied (so the modal falls
# back to a plain fade-out for the chosen card).
const NO_ARC_TARGET := Vector2(-1e9, -1e9)

class _Request:
	var pool: Array
	var pack_size: int
	var on_picked: Callable
	var arc_target_world: Vector2

	func _init(p_pool: Array, p_pack_size: int, p_on_picked: Callable, p_arc_target: Vector2) -> void:
		pool = p_pool
		pack_size = p_pack_size
		on_picked = p_on_picked
		arc_target_world = p_arc_target

var _queue: Array = []                     # Array[_Request]
var _modal: Node = null                    # Lazily instantiated
var _active: _Request = null

func request(pool: Array, pack_size: int = 3, on_picked: Callable = Callable(), arc_target_world: Vector2 = NO_ARC_TARGET) -> void:
	if pool.is_empty() or pack_size <= 0:
		return
	_queue.append(_Request.new(pool, pack_size, on_picked, arc_target_world))
	_pump()

func is_active() -> bool:
	return _active != null

# ---------------------------------------------------------------------------
# Internal

func _pump() -> void:
	if _active != null:
		return
	if _queue.is_empty():
		finished.emit()
		return
	_active = _queue.pop_front()
	_ensure_modal()
	var pack: Array = _sample(_active.pool, _active.pack_size)
	_modal.present(pack, _active.arc_target_world)
	started.emit()

func _ensure_modal() -> void:
	if _modal != null:
		return
	_modal = MODAL_SCENE.instantiate()
	add_child(_modal)
	_modal.picked.connect(_on_picked)

func _on_picked(chosen: CardData) -> void:
	var done := _active
	_active = null
	if done != null and done.on_picked.is_valid():
		done.on_picked.call(chosen)
	_pump()

func _sample(pool: Array, n: int) -> Array:
	# Draw without replacement. If pool is smaller than n, pack just shrinks —
	# simplest behaviour, fine for early development.
	var copy: Array = pool.duplicate()
	copy.shuffle()
	return copy.slice(0, mini(n, copy.size()))
