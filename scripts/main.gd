extends Node2D

# Game flow controller. Owns:
#   - turn-phase state machine (DRAW → PLAY → END_TURN)
#   - card play dispatch via the can_stack tag system
#   - threshold-play effects (exile, generic effect dispatcher, synergy triggers)
#   - the discovery pool (planets + stars revealed by playing Discover)
#   - per-turn journal entry fly-in from off-screen right
#
# Persistent run state lives in `GameState` (autoload). Board state (cells,
# stacks) lives in the play_space scene tree — walk that when you need to
# query what's on the board.

const CARD_SCENE := preload("res://scenes/card.tscn")
const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")

const TIME_SCALE := 1.0

const TURN_DRAW_COUNT := 5
const DRAW_STAGGER_SEC := 0.12
const DISCARD_STAGGER_SEC := 0.06

# Drafts: colonies open every 5 turns, other buildings (incl. synergy)
# every 10 turns. Picked card lands in discard.
const COLONY_DRAFT_INTERVAL := 5
const COLONY_DRAFT_PACK_SIZE := 3
const BUILDING_DRAFT_INTERVAL := 10
const BUILDING_DRAFT_PACK_SIZE := 3

const RESHUFFLE_STAGGER := 0.05
const RESHUFFLE_FLY_DURATION := 0.5
const RESHUFFLE_MAX_VISIBLE := 8
const RESHUFFLE_ARC_PEAK := 90.0

const SHOWCASE_SLOT_SPACING := 110.0

# Card definitions live in data/card_library.tres. The starting deck just
# references the .tres files directly — keeps it explicit which cards seed
# the run without needing any lookup.
const CARD_LIBRARY: CardLibrary = preload("res://data/card_library.tres")
const CARD_BUILD_COLONY: CardData = preload("res://data/cards/build_colony.tres")
const CARD_DISCOVER: CardData = preload("res://data/cards/discover.tres")
const CARD_CONTACT: CardData = preload("res://data/cards/contact.tres")

var STARTING_DECK: Array[CardData] = [
	CARD_BUILD_COLONY,
	CARD_DISCOVER,
	CARD_DISCOVER,
]

# Authored planet pool lives in data/planet_library.tres. The discovery pool
# is seeded from this plus EXTRA_PLANETS (procedural) plus a 5% sprinkling
# of stars.
const PLANET_LIBRARY: PlanetLibrary = preload("res://data/planet_library.tres")

# Procedural planets to top up the discovery pool. [name, types[]].
const EXTRA_PLANETS: Array = [
	["Cinder Reach", ["Rocky"]],
	["Verdant", ["Rocky"]],
	["Solace", ["Rocky", "Oceanic"]],
	["Marrowfell", ["Rocky"]],
	["Greythorne", ["Rocky", "Ice"]],
	["Brackwater", ["Oceanic"]],
	["Coral Drift", ["Oceanic"]],
	["Tidal Cradle", ["Oceanic", "Ice"]],
	["Reefhold", ["Oceanic"]],
	["Saltspire", ["Oceanic", "Rocky"]],
	["Whitebrim", ["Ice"]],
	["Rimepeak", ["Ice", "Rocky"]],
	["Hoarfrost", ["Ice"]],
	["Snowgale", ["Ice"]],
	["Glasspane", ["Ice", "Oceanic"]],
	["Stormcradle", ["Gas Giant"]],
	["Aetherwind", ["Gas Giant"]],
	["Thalassara", ["Gas Giant", "Ice"]],
	["Cyclonis", ["Gas Giant"]],
	["Hexavault", ["Gas Giant"]],
	["Wraithdust", ["Rocky", "Ice"]],
	["Pyrelands", ["Rocky"]],
	["Embergloom", ["Rocky"]],
	["Glasshollow", ["Rocky", "Ice"]],
	["Ferralis", ["Rocky"]],
	["Brinemarch", ["Oceanic"]],
	["Black Mire", ["Oceanic", "Rocky"]],
	["Aurora Bay", ["Oceanic", "Ice"]],
	["Driftholm", ["Oceanic"]],
	["Blue Veil", ["Oceanic", "Gas Giant"]],
	["Frostgate", ["Ice"]],
	["Glacier's Eye", ["Ice", "Oceanic"]],
	["Stillpane", ["Ice"]],
	["Cathedra", ["Ice", "Rocky"]],
	["Snowhold", ["Ice"]],
	["Vortexis", ["Gas Giant"]],
	["Halcyon", ["Gas Giant", "Ice"]],
	["Stormveil II", ["Gas Giant"]],
	["Caelumar", ["Gas Giant"]],
	["Maelstrome", ["Gas Giant", "Oceanic"]],
	["Quietstone", ["Rocky"]],
	["Cradle of Bones", ["Rocky"]],
	["Hollow Moor", ["Rocky", "Ice"]],
	["Dustbarrow", ["Rocky"]],
	["Lumen", ["Rocky", "Ice"]],
	["Aquanis", ["Oceanic"]],
	["Cobalt Reach", ["Oceanic", "Rocky"]],
	["Ven Tellaris", ["Rocky", "Oceanic"]],
	["Argentum", ["Ice", "Rocky"]],
	["Helica", ["Gas Giant"]],
]

const STAR_NAMES: Array = [
	"Sol", "Helios", "Polaris", "Vega", "Sirius", "Antares", "Rigel", "Arcturus",
]

const ALIEN_SHIP_NAMES: Array = [
	"Drifting Hulk",
	"Silent Vessel",
	"Ghost Sail",
	"Wandering Echo",
	"Cold Anchor",
]

# Total worlds in the discovery pool (planets + stars combined).
const TOTAL_DISCOVERY_WORLDS := 60
const STAR_FRACTION := 0.05

# Per-turn random alien-ship arrival.
const ALIEN_SHIP_TURN_CHANCE := 0.04

const HOMEWORLD_POSITION := Vector2(540, 220)
const JOURNAL_POSITION := Vector2(140, 150)

const JOURNAL_ENTRIES_PATH := "res://data/journal_entries.txt"

enum Phase { DRAW, PLAY, END_TURN }

@onready var deck: Deck = $PlayerDeck
@onready var hand: Hand = $HandLayer/Hand
@onready var discard: DiscardPile = $DiscardPile
@onready var exile_pile: ExilePile = $ExilePile
@onready var play_space: PlaySpace = $PlaySpace
@onready var hud: Hud = $Hud
@onready var end_turn_button: Button = $EndTurnButton
@onready var card_shuffle_audio: AudioStreamPlayer2D = $CardShuffleAudioStreamPlayer2D
@onready var card_slap_audio: AudioStreamPlayer2D = $CardSlapAudioStreamPlayer2D
@onready var card_hover_audio: AudioStreamPlayer2D = $CardHoverAudioStreamPlayer2D
# Cast required because the script class_name doesn't propagate through
# `$NodePath` lookup (the static root type is `CanvasLayer`).
@onready var pile_viewer: PileViewer = $PileViewer as PileViewer

var _showcasing: Array[Card] = []
var _play_counter: int = 0
var _turn_transitioning: bool = false
var _journal_entries: Array[String] = []
var _next_journal_index: int = 0

# Discovery pool — face-down planets + stars, popped one at a time when the
# player plays a Discover. Stored as Array[CardData].
var _discovery_pool: Array = []

func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	hand.card_played.connect(_on_card_played)
	hand.play_space = play_space
	play_space.hand = hand
	hand.hover_audio = card_hover_audio
	play_space.hover_audio = card_hover_audio
	# Anchor where new worlds + journal entries fly in from — off-screen right.
	var vp := get_viewport_rect().size
	play_space.set_offscreen_origin(Vector2(vp.x + 200.0, 240.0))
	end_turn_button.pressed.connect(_on_end_turn)
	# Pile-viewer wiring: clicking any pile pops a viewer with its contents.
	deck.pile_clicked.connect(_open_draw_pile_viewer)
	discard.pile_clicked.connect(_open_discard_pile_viewer)
	exile_pile.pile_clicked.connect(_open_exile_pile_viewer)
	pile_viewer.dismissed.connect(_on_pile_viewer_dismissed)
	# Draft modal pauses hand input while open, mirroring the pile viewer.
	Draft.started.connect(_on_draft_started)
	Draft.finished.connect(_on_draft_finished)
	_init_game_state()
	_start_first_turn()

func _init_game_state() -> void:
	GameState.turn_number = 1
	GameState.player_discard.clear()
	GameState.player_exile.clear()
	GameState.total_buildings_placed = 0

	GameState.player_deck = STARTING_DECK.duplicate()
	GameState.player_deck.shuffle()

	_journal_entries = _load_journal_entries()
	_next_journal_index = 0

	# Build the planet pool: authored .tres planets + procedural extras.
	# Duplicate so we can mutate (e.g. rename Homeworld) without touching .tres.
	var planets: Array = []
	for p in PLANET_LIBRARY.planets:
		planets.append(p.duplicate() as CardData)
	for entry in EXTRA_PLANETS:
		planets.append(_make_planet_card(entry[0], entry[1]))
	planets.shuffle()

	# Reserve a Rocky planet for Homeworld (rename + place).
	var homeworld: CardData = null
	for i in range(planets.size()):
		if "Rocky" in planets[i].planet_types:
			homeworld = planets[i]
			planets.remove_at(i)
			break
	if homeworld == null:
		homeworld = planets.pop_front()
	homeworld.card_name = "Homeworld"
	play_space.place_card_immediate(homeworld, HOMEWORLD_POSITION)

	# Trim down to the configured planet count and add stars on top.
	var star_count: int = int(round(TOTAL_DISCOVERY_WORLDS * STAR_FRACTION))
	var planet_count: int = TOTAL_DISCOVERY_WORLDS - star_count
	while planets.size() > planet_count:
		planets.pop_back()
	var stars: Array = []
	for i in range(star_count):
		var name: String = STAR_NAMES[i % STAR_NAMES.size()]
		if i >= STAR_NAMES.size():
			name = "%s %d" % [name, i / STAR_NAMES.size() + 1]
		stars.append(_make_star_card(name))

	_discovery_pool.clear()
	for p in planets:
		_discovery_pool.append(p)
	for s in stars:
		_discovery_pool.append(s)
	_discovery_pool.shuffle()

	# Place the journal anchor so journal entries have something to stack onto.
	var journal := _make_journal_card()
	play_space.place_card_immediate(journal, JOURNAL_POSITION)

	deck.cards_remaining = GameState.player_deck.size()
	discard.cards_remaining = 0
	exile_pile.cards_remaining = 0

func _make_planet_card(name: String, types: Array) -> CardData:
	var cd := CardData.new()
	cd.card_name = name
	cd.card_types = ["planet"]
	var typed: Array[String] = []
	for t in types:
		typed.append(String(t))
	cd.planet_types = typed
	return cd

func _make_star_card(name: String) -> CardData:
	var cd := CardData.new()
	cd.card_name = name
	cd.card_types = ["star"]
	return cd

func _make_journal_card() -> CardData:
	var cd := CardData.new()
	cd.card_name = "Journal"
	cd.card_types = ["journal"]
	return cd

func _make_alien_ship_card(ship_name: String) -> CardData:
	var cd := CardData.new()
	cd.card_name = ship_name
	cd.card_types = ["alien_ship"]
	return cd

func _make_journal_entry_card() -> CardData:
	var cd := CardData.new()
	cd.card_name = "Journal"
	cd.body = ""
	var tags: Array[String] = ["journal"]
	cd.card_types = tags
	cd.can_stack = tags.duplicate()
	return cd

func _load_journal_entries() -> Array[String]:
	var entries: Array[String] = []
	var f := FileAccess.open(JOURNAL_ENTRIES_PATH, FileAccess.READ)
	if f == null:
		push_error("Journal entries file missing: %s" % JOURNAL_ENTRIES_PATH)
		return entries
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "":
			entries.append(line)
	f.close()
	return entries

func _start_first_turn() -> void:
	_run_draw_phase()
	_set_phase(Phase.PLAY)

# ---------------------------------------------------------------------------
# Phase machine

func _set_phase(p: int) -> void:
	GameState.turn_phase_changed.emit(p)

func _on_end_turn() -> void:
	if _turn_transitioning or hand.is_dragging():
		return
	_turn_transitioning = true
	_run_end_turn_phase()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			if pile_viewer.is_open():
				pile_viewer.hide_viewer()
			else:
				get_tree().quit()
		elif event.keycode == KEY_SPACE:
			_on_end_turn()

# ---------------------------------------------------------------------------
# DRAW phase

func _run_draw_phase() -> void:
	_set_phase(Phase.DRAW)
	_age_buildings()
	_fly_in_journal_entry()
	if randf() < ALIEN_SHIP_TURN_CHANCE:
		_fly_in_alien_ship()
	for i in range(TURN_DRAW_COUNT):
		get_tree().create_timer(float(i) * DRAW_STAGGER_SEC).timeout.connect(_draw_one_card)
	var draw_total: float = float(TURN_DRAW_COUNT - 1) * DRAW_STAGGER_SEC + 0.05
	get_tree().create_timer(draw_total).timeout.connect(_clear_turn_transition)

func _fly_in_journal_entry() -> void:
	# Auto-arrival each turn, regardless of whether the player has a Discover.
	# Text comes from the sequential journal_entries.txt file.
	var entry := _make_journal_entry_card()
	if _next_journal_index < _journal_entries.size():
		entry.body = _journal_entries[_next_journal_index]
		_next_journal_index += 1
	play_space.emit_card_onto_stack(entry, "journal")

func _fly_in_alien_ship() -> void:
	var ship_name: String = ALIEN_SHIP_NAMES[randi() % ALIEN_SHIP_NAMES.size()]
	play_space.emit_card_to_cell(_make_alien_ship_card(ship_name))

func _clear_turn_transition() -> void:
	_turn_transitioning = false

func _draw_one_card() -> void:
	if GameState.player_deck.is_empty() and not GameState.player_discard.is_empty():
		var recycled: int = GameState.player_discard.size()
		GameState.player_deck = GameState.player_discard.duplicate()
		GameState.player_deck.shuffle()
		GameState.player_discard.clear()
		deck.cards_remaining = recycled
		discard.cards_remaining = 0
		card_shuffle_audio.play()
		_animate_reshuffle(recycled)
	if GameState.player_deck.is_empty():
		return
	var def: CardData = GameState.player_deck.pop_back()
	deck.cards_remaining = GameState.player_deck.size()
	var card: Card = CARD_SCENE.instantiate()
	card.configure(def)
	hand.add_card(card, deck.global_position)

# ---------------------------------------------------------------------------
# END_TURN phase — discard hand, advance turn counter, draw next hand

func _run_end_turn_phase() -> void:
	_set_phase(Phase.END_TURN)
	hand.clear_hover()
	var hand_cards := hand.cards.duplicate()
	# Logically place cards into discard immediately so the deck/discard
	# counters stay correct even mid-flight.
	for c in hand_cards:
		GameState.player_discard.append(c.data)
	discard.cards_remaining += hand_cards.size()
	hand.cards.clear()
	hand.layout()
	var delay := 0.0
	for card in hand_cards:
		get_tree().create_timer(delay).timeout.connect(_discard_one.bind(card))
		delay += DISCARD_STAGGER_SEC

	GameState.turn_number += 1
	hud.set_turn(GameState.turn_number)
	_run_draw_phase()

func _discard_one(card: Card) -> void:
	card.fly_finished.connect(_on_card_fly_finished, CONNECT_ONE_SHOT)
	card.discard_fly(discard.global_position)

# ---------------------------------------------------------------------------
# Card play dispatch

func _on_card_played(card: Card, target_card) -> void:
	# Two play paths:
	#   1. Stack — `target_card` is the topmost card whose stack accepted this
	#      card's can_stack tags. The card is reparented under that stack's
	#      leaf as a permanent visual; on placement we mint any
	#      spawns_on_placement (resources, Discover) into discard.
	#   2. Threshold — `target_card` is null. The card was released above the
	#      hand threshold. Routes to exile or discard, then runs effects:
	#      its own effect_id (e.g. Discover), and any synergy triggers from
	#      cards in play (only for resource plays).
	if target_card != null:
		GameState.total_buildings_placed += 1
		play_space.attach_card_to_stack(card, target_card)
		card_slap_audio.play()
		_on_card_placed(card)
		return
	var played_data: CardData = card.data
	if played_data != null and played_data.exiles_on_play:
		_send_card_to_exile(card)
	else:
		_send_card_to_discard(card)
	if played_data != null:
		_dispatch_play_effects(played_data)

func _on_card_placed(card: Card) -> void:
	# Mint any cards the building generates on placement (resources, Discover)
	# into the discard pile. They cycle back to hand on the next reshuffle.
	if card.data == null:
		return
	if card.data.spawns_on_placement.is_empty():
		return
	for spawn in card.data.spawns_on_placement:
		if spawn != null:
			GameState.player_discard.append(spawn)
	discard.cards_remaining = GameState.player_discard.size()

func _send_card_to_discard(card: Card) -> void:
	GameState.player_discard.append(card.data)
	discard.cards_remaining = GameState.player_discard.size()
	_animate_play_to_pile(card, discard.global_position)

func _send_card_to_exile(card: Card) -> void:
	GameState.player_exile.append(card.data)
	exile_pile.cards_remaining = GameState.player_exile.size()
	_animate_play_to_pile(card, exile_pile.global_position)

# ---------------------------------------------------------------------------
# Effect dispatch
#
# Two rounds when a threshold-played card resolves:
#   1) Run the card's own effect_id (Discover reveals a world; resources
#      themselves usually have none).
#   2) For resource plays specifically, walk every card in play and fire any
#      whose triggers_on_play_tags overlaps with the played resource's tags.

func _dispatch_play_effects(played_data: CardData) -> void:
	_run_effect(played_data.effect_id, played_data.effect_amount, played_data.effect_payload)
	if not ("resource" in played_data.card_types):
		return
	for c in play_space.all_cards():
		if c.data == null:
			continue
		if c.data.triggers_on_play_tags.is_empty():
			continue
		for tag in c.data.triggers_on_play_tags:
			if tag in played_data.card_types:
				_run_effect(c.data.effect_id, c.data.effect_amount, c.data.effect_payload)
				break

func _run_effect(effect_id: String, amount: int, payload: CardData) -> void:
	match effect_id:
		"":
			return
		"draw":
			for i in range(amount):
				_draw_one_card()
		"add_to_discard":
			if payload != null:
				for i in range(amount):
					GameState.player_discard.append(payload)
				discard.cards_remaining = GameState.player_discard.size()
		"discover":
			_discover_one_from_pool()
		_:
			push_warning("Unknown effect_id: %s" % effect_id)

func _discover_one_from_pool() -> void:
	if _discovery_pool.is_empty():
		return
	var entry: CardData = _discovery_pool.pop_back()
	play_space.emit_card_to_cell(entry)

# ---------------------------------------------------------------------------
# Play-to-pile animation

func _animate_play_to_pile(card: Card, target_world_pos: Vector2) -> void:
	_showcasing.append(card)
	_play_counter += 1
	card.z_index = ZLayers.SHOWCASE_BASE + _play_counter
	card.showcase_done.connect(_on_showcase_done, CONNECT_ONE_SHOT)
	card.fly_finished.connect(_on_card_fly_finished, CONNECT_ONE_SHOT)
	var n := _showcasing.size()
	card.end_drag_fly(target_world_pos, _showcase_position(n - 1, n))
	for i in range(n - 1):
		_showcasing[i].update_showcase_target(_showcase_position(i, n))

func _on_showcase_done(card: Card) -> void:
	_showcasing.erase(card)
	var n := _showcasing.size()
	for i in range(n):
		_showcasing[i].update_showcase_target(_showcase_position(i, n))
	if n == 0:
		_play_counter = 0

func _on_card_fly_finished(card: Card) -> void:
	card.queue_free()

func _showcase_position(index: int, total: int) -> Vector2:
	var center := get_viewport_rect().size * 0.5
	if total <= 1:
		return center
	var offset_x := (float(index) - (float(total) - 1.0) * 0.5) * SHOWCASE_SLOT_SPACING
	return center + Vector2(offset_x, 0.0)

# ---------------------------------------------------------------------------
# Building drafts — colonies every 5 turns of life, other buildings every 10.
# Pool composition:
#   - Colony pool: building cards (no synergy) + Discover + Contact (if a
#     ship is on the board).
#   - Non-colony building pool: synergy cards whose triggers_on_play_tags
#     overlap with the building's produced-resource tags.

func _age_buildings() -> void:
	for c in play_space.all_cards():
		# Roots are world anchors (planet, journal, alien_ship, star). Skip —
		# only stacked cards age.
		if not (c.get_parent() is Card):
			continue
		c.turns_alive += 1
		if c.data == null:
			continue
		var is_colony := "colony" in c.card_types
		var is_synergy := "synergy" in c.card_types
		var is_building := "building" in c.card_types
		if is_colony and c.turns_alive > 0 and c.turns_alive % COLONY_DRAFT_INTERVAL == 0:
			Draft.request(_colony_draft_pool(), COLONY_DRAFT_PACK_SIZE, _on_card_drafted, discard.global_position)
		elif is_building and not is_colony and c.turns_alive > 0 and c.turns_alive % BUILDING_DRAFT_INTERVAL == 0:
			var pool := _building_draft_pool(c.data)
			if not pool.is_empty():
				Draft.request(pool, BUILDING_DRAFT_PACK_SIZE, _on_card_drafted, discard.global_position)

func _colony_draft_pool() -> Array:
	var pool: Array = []
	for c in CARD_LIBRARY.cards:
		if "building" in c.card_types and not ("synergy" in c.card_types):
			pool.append(c)
	if play_space.has_card_with_tag("alien_ship"):
		pool.append(CARD_CONTACT)
	pool.append(CARD_DISCOVER)
	return pool

func _building_draft_pool(building_data: CardData) -> Array:
	# Specialty tags = the building's produced-resource tags (resource buildings)
	# OR its own triggers_on_play_tags (synergy buildings). Pool = synergy cards
	# whose triggers_on_play_tags overlap with the specialty tags. Excludes
	# the building itself.
	var specialty: Array = []
	for spawn in building_data.spawns_on_placement:
		if spawn == null:
			continue
		for t in spawn.card_types:
			if not (t in specialty):
				specialty.append(t)
	for t in building_data.triggers_on_play_tags:
		if not (t in specialty):
			specialty.append(t)
	if specialty.is_empty():
		return []
	var pool: Array = []
	for c in CARD_LIBRARY.cards:
		if c == building_data:
			continue
		if not ("synergy" in c.card_types):
			continue
		for tag in c.triggers_on_play_tags:
			if tag in specialty:
				pool.append(c)
				break
	return pool

func _on_card_drafted(chosen: CardData) -> void:
	if chosen == null:
		return
	GameState.player_discard.append(chosen)
	discard.cards_remaining = GameState.player_discard.size()

func _on_draft_started() -> void:
	hand.input_paused = true
	play_space.input_paused = true

func _on_draft_finished() -> void:
	hand.input_paused = false
	play_space.input_paused = false

# ---------------------------------------------------------------------------
# Pile viewers (draw/discard/exile)

func _open_draw_pile_viewer() -> void:
	_open_pile_viewer("Draw Pile", GameState.player_deck)

func _open_discard_pile_viewer() -> void:
	_open_pile_viewer("Discard Pile", GameState.player_discard)

func _open_exile_pile_viewer() -> void:
	_open_pile_viewer("Exile Pile", GameState.player_exile)

func _open_pile_viewer(title: String, cards: Array) -> void:
	hand.input_paused = true
	pile_viewer.show_pile(title, cards)

func _on_pile_viewer_dismissed() -> void:
	hand.input_paused = false

# ---------------------------------------------------------------------------
# Reshuffle (discard → deck) cosmetic animation.

func _animate_reshuffle(count: int) -> void:
	var n: int = mini(count, RESHUFFLE_MAX_VISIBLE)
	for i in range(n):
		get_tree().create_timer(float(i) * RESHUFFLE_STAGGER).timeout.connect(_spawn_reshuffle_back)

func _spawn_reshuffle_back() -> void:
	var back: Node2D = CARD_BACK_SCENE.instantiate()
	add_child(back)
	back.position = discard.global_position
	back.z_index = ZLayers.RESHUFFLE

	var start: Vector2 = back.position
	var end: Vector2 = deck.global_position
	var midpoint := (start + end) * 0.5
	var control := midpoint + Vector2(0.0, -RESHUFFLE_ARC_PEAK)

	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.set_trans(Tween.TRANS_CUBIC)
	tween.tween_method(_reshuffle_arc.bind(back, start, control, end), 0.0, 1.0, RESHUFFLE_FLY_DURATION)
	tween.parallel().tween_property(back, "rotation", -PI, RESHUFFLE_FLY_DURATION)
	tween.parallel().tween_property(back, "scale", Vector2(0.85, 0.85), RESHUFFLE_FLY_DURATION)
	tween.finished.connect(back.queue_free)

func _reshuffle_arc(t: float, back: Node2D, start: Vector2, control: Vector2, end: Vector2) -> void:
	var u := 1.0 - t
	back.position = u * u * start + 2.0 * u * t * control + t * t * end
