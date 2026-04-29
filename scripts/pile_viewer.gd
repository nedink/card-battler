class_name PileViewer extends Control

# Full-screen overlay that shows every card in a pile (deck/discard/exile) as
# a grid of mini Card instances. Clicking the dim backdrop or pressing Esc
# dismisses it.
#
# Calls into card.gd's `configure()` so the rendered mini cards reuse the
# exact same visuals (cost icons, name, body text, color) as live cards.

signal dismissed

const CARD_SCENE := preload("res://scenes/card.tscn")

# Mini-card layout constants. Card.SIZE is the unscaled body extent; CARD_SCALE
# shrinks the rendered card so a full pile fits in the panel grid.
const CARD_SCALE := 0.7
const CARD_W := Card.SIZE.x * CARD_SCALE
const CARD_H := Card.SIZE.y * CARD_SCALE
# Gaps follow the card aspect ratio so horizontal/vertical breathing room reads
# consistently regardless of scale.
const GAP_X := 14.0
const GAP_Y := GAP_X * (Card.SIZE.y / Card.SIZE.x)
const CARDS_PER_ROW := 9

# Panel inner content layout. PANEL_GRID_TOP leaves room for the title row;
# the grid is then vertically centred within the remaining space.
const PANEL_GRID_TOP := 64.0
const PANEL_GRID_BOTTOM_PAD := 24.0

@onready var _backdrop: ColorRect = $Backdrop
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _empty: Label = $Panel/Empty
@onready var _cards_root: Node2D = $Panel/Cards

func _ready() -> void:
	_backdrop.gui_input.connect(_on_backdrop_input)
	_panel.gui_input.connect(_on_backdrop_input)
	visible = false

func is_open() -> bool:
	return visible

# `entries` is an Array[CardData]. Cards are rendered alphabetically so the
# pile's draw order isn't leaked through this UI.
func show_pile(title: String, entries: Array) -> void:
	_title.text = title
	for c in _cards_root.get_children():
		c.queue_free()
	if entries.is_empty():
		_empty.visible = true
		_empty.text = "Pile is empty."
	else:
		_empty.visible = false
		var sorted := entries.duplicate()
		sorted.sort_custom(func(a, b): return String(a.card_name) < String(b.card_name))
		var panel_w: float = _panel.size.x
		var panel_h: float = _panel.size.y
		var rows: int = int(ceil(float(sorted.size()) / float(CARDS_PER_ROW)))
		# Vertically centre the grid within the area below the title.
		var grid_h: float = float(rows) * CARD_H + float(maxi(rows - 1, 0)) * GAP_Y
		var grid_avail_h: float = panel_h - PANEL_GRID_TOP - PANEL_GRID_BOTTOM_PAD
		var y_off: float = PANEL_GRID_TOP + maxf((grid_avail_h - grid_h) * 0.5, 0.0)
		for i in range(sorted.size()):
			var def: CardData = sorted[i]
			var card: Card = CARD_SCENE.instantiate()
			_cards_root.add_child(card)
			card.configure(def)
			# Cards are display-only here; let clicks fall through to the panel's
			# gui_input handler (and through it to the backdrop) so the user can
			# dismiss the viewer by clicking anywhere — over a card, the panel
			# background, or the dim backdrop.
			_disable_input(card)
			card.scale = Vector2(CARD_SCALE, CARD_SCALE)
			var col: int = i % CARDS_PER_ROW
			var row: int = i / CARDS_PER_ROW
			# Centre each row horizontally within the panel.
			var row_count: int = mini(sorted.size() - row * CARDS_PER_ROW, CARDS_PER_ROW)
			var row_width: float = float(row_count) * CARD_W + float(row_count - 1) * GAP_X
			var x_off: float = (panel_w - row_width) * 0.5
			# Card's origin is its centre (Body offsets are ±SIZE/2), so the cell's
			# top-left at (x_off + col*step, y_off + row*step) plus half-card lands
			# the centre at the right spot regardless of CARD_SCALE.
			card.position = Vector2(
				x_off + float(col) * (CARD_W + GAP_X) + CARD_W * 0.5,
				y_off + float(row) * (CARD_H + GAP_Y) + CARD_H * 0.5)
	visible = true

func hide_viewer() -> void:
	visible = false
	for c in _cards_root.get_children():
		c.queue_free()
	dismissed.emit()

func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hide_viewer()

func _disable_input(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in node.get_children():
		_disable_input(c)
