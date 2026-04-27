class_name PileViewer extends Control

# Full-screen overlay that shows every card in a pile (deck/discard/exile) as
# a grid of mini Card instances. Clicking the dim backdrop or pressing Esc
# dismisses it.
#
# Calls into card.gd's `configure()` so the rendered mini cards reuse the
# exact same visuals (cost icons, name, body text, color) as live cards.

signal dismissed

const CARD_SCENE := preload("res://scenes/card.tscn")

# Mini-card layout constants. Card SIZE is 120×168; at 0.7 scale that's 84×118.
const CARD_SCALE := 0.7
const CARD_W := 120.0 * CARD_SCALE
const CARD_H := 168.0 * CARD_SCALE
const GAP_X := 14.0
const GAP_Y := 18.0
const CARDS_PER_ROW := 9

# Panel inner content layout. The panel is anchored via offsets in the scene;
# these are inner offsets within the panel for laying out the grid.
const PANEL_INNER_LEFT := 24.0
const PANEL_INNER_TOP_TITLE := 16.0
const PANEL_GRID_TOP := 64.0       # Below the title row.

@onready var _backdrop: ColorRect = $Backdrop
@onready var _panel: Panel = $Panel
@onready var _title: Label = $Panel/Title
@onready var _empty: Label = $Panel/Empty
@onready var _cards_root: Node2D = $Panel/Cards

func _ready() -> void:
	_backdrop.gui_input.connect(_on_backdrop_input)
	visible = false

func is_open() -> bool:
	return visible

# `entries` is an Array of Dictionaries with the same shape as main.gd's
# CARD_DEFS values, plus a "type" key holding the Card.CardType int. The
# caller assembles them so this script doesn't have to know about CARD_DEFS.
func show_pile(title: String, entries: Array) -> void:
	_title.text = title
	for c in _cards_root.get_children():
		c.queue_free()
	if entries.is_empty():
		_empty.visible = true
		_empty.text = "Pile is empty."
	else:
		_empty.visible = false
		# Sort alphabetically by name so the deck order isn't leaked.
		var sorted := entries.duplicate()
		sorted.sort_custom(func(a, b): return String(a.get("name", "")) < String(b.get("name", "")))
		var panel_w: float = _panel.size.x
		for i in range(sorted.size()):
			var def: Dictionary = sorted[i]
			var card: Card = CARD_SCENE.instantiate()
			_cards_root.add_child(card)
			card.configure(
				String(def.get("name", "?")),
				int(def.get("type", 0)),
				int(def.get("cost", 0)),
				String(def.get("resource", "credits")),
				String(def.get("body", "")))
			card.scale = Vector2(CARD_SCALE, CARD_SCALE)
			var col: int = i % CARDS_PER_ROW
			var row: int = i / CARDS_PER_ROW
			# Centre each row horizontally within the panel.
			var row_count: int = mini(sorted.size() - row * CARDS_PER_ROW, CARDS_PER_ROW)
			var row_width: float = float(row_count) * CARD_W + float(row_count - 1) * GAP_X
			var x_off: float = (panel_w - row_width) * 0.5
			# Card.position is its centre (Card is a Node2D with Body offsets ±60/±84
			# baked in), so add half-card to the top-left of each cell.
			card.position = Vector2(
				x_off + float(col) * (CARD_W + GAP_X) + CARD_W * 0.5,
				PANEL_GRID_TOP + float(row) * (CARD_H + GAP_Y) + CARD_H * 0.5)
	visible = true

func hide_viewer() -> void:
	visible = false
	for c in _cards_root.get_children():
		c.queue_free()
	dismissed.emit()

func _on_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		hide_viewer()
