extends Node2D

# Game flow controller. Owns:
#   - turn-phase state machine (DRAW → PLAY → END_TURN)
#   - card play dispatch via the can_stack tag system
#
# All persistent run state lives in `GameState` (autoload). The board state
# (cells, stacks) lives in the play_space scene tree — walk that when you
# need to query what's on the board.
#
# NOTE — events: A per-turn random EVENT phase used to live here (Meteor
# Strike, etc.). It was stripped during the v0 simplification. When the systems
# mature we want events back: a phase slot before DRAW, a small library of
# effects keyed by tags on planets and buildings, and the EventCard banner
# (still in res://scenes/) reused as the announcement visual.

const CARD_SCENE := preload("res://scenes/card.tscn")
const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")

const TIME_SCALE := 1.0

const TURN_DRAW_COUNT := 5
const DRAW_STAGGER_SEC := 0.12
const DISCARD_STAGGER_SEC := 0.06

# Colonies open a draft pack of `COLONY_DRAFT_PACK_SIZE` cards every
# `COLONY_DRAFT_INTERVAL` turns of their life. Picked card lands in the
# discard pile.
const COLONY_DRAFT_INTERVAL := 5
const COLONY_DRAFT_PACK_SIZE := 3

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
const CARD_CONTACT: CardData = preload("res://data/cards/contact.tres")

var STARTING_DECK: Array[CardData] = [
	CARD_BUILD_COLONY,
]

# Planet pool lives in data/planet_library.tres — add/edit planet defs there.
# Each entry is a CardData with the "planet" tag and a populated planet_type.
const PLANET_LIBRARY: PlanetLibrary = preload("res://data/planet_library.tres")

# Discovery deck composition. Per turn we pop the top of GameState.planet_deck_data
# and dispatch by tag: "journal" entries stack onto the board's Journal anchor;
# everything else (planets, alien ships) settles into a free play-space cell.
# Journal entries dominate by count to give the deck its narrative texture.
#
# Journal text is loaded from a sidecar file and revealed in strict sequential
# order, regardless of where the journal-entry cards land in the shuffled
# discovery deck. The cards seeded into the deck are anonymous placeholders;
# their body is assigned at reveal time from `_journal_entries[_next_journal_index]`.
const JOURNAL_ENTRIES_PATH := "res://data/journal_entries.txt"
const ALIEN_SHIP_NAMES: Array[String] = [
	"Drifting Hulk",
	"Silent Vessel",
]
const HOMEWORLD_POSITION := Vector2(540, 220)
const JOURNAL_POSITION := Vector2(140, 150)

enum Phase { DRAW, PLAY, END_TURN }

@onready var deck: Deck = $PlayerDeck
@onready var hand: Hand = $HandLayer/Hand
@onready var discard: DiscardPile = $DiscardPile
@onready var exile_pile: ExilePile = $ExilePile
@onready var planet_deck: Deck = $PlanetDeck
@onready var play_space: PlaySpace = $PlaySpace
@onready var hud: Hud = $Hud
@onready var end_turn_button: Button = $EndTurnButton
@onready var card_shuffle_audio: AudioStreamPlayer2D = $CardShuffleAudioStreamPlayer2D
@onready var card_slap_audio: AudioStreamPlayer2D = $CardSlapAudioStreamPlayer2D
# Cast required because the script class_name doesn't propagate through
# `$NodePath` lookup (the static root type is `CanvasLayer`).
@onready var pile_viewer: PileViewer = $PileViewer as PileViewer

var _showcasing: Array[Card] = []
var _play_counter: int = 0
var _turn_transitioning: bool = false
var _journal_entries: Array[String] = []
var _next_journal_index: int = 0

func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	hand.card_played.connect(_on_card_played)
	hand.play_space = play_space
	play_space.hand = hand
	play_space.set_planet_deck_position(planet_deck.global_position)
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

	# Planets first: shuffled, with one rocky world reserved as the Homeworld.
	# Duplicate so we can rename ours to "Homeworld" without mutating the .tres.
	var planet_pool: Array[CardData] = []
	for p in PLANET_LIBRARY.planets:
		planet_pool.append(p.duplicate() as CardData)
	planet_pool.shuffle()
	var homeworld: CardData = null
	for i in range(planet_pool.size()):
		if planet_pool[i].planet_type == "Rocky":
			homeworld = planet_pool[i]
			planet_pool.remove_at(i)
			break
	if homeworld == null:
		homeworld = planet_pool.pop_front()
	homeworld.card_name = "Homeworld"
	play_space.place_card_immediate(homeworld, HOMEWORLD_POSITION)

	# Journal: a single on-board card cards stack onto when journal entries are
	# discovered. Modelled as a CardData with the "journal" tag so the existing
	# stack/visual system carries it.
	var journal := _make_journal_card()
	play_space.place_card_immediate(journal, JOURNAL_POSITION)

	# Discovery deck: planets + alien ships + journal entries (the bulk),
	# shuffled together. Each turn the top is revealed and dispatched.
	var discovery: Array = []
	for p in planet_pool:
		discovery.append(p)
	for ship_name in ALIEN_SHIP_NAMES:
		discovery.append(_make_alien_ship_card(ship_name))
	for i in range(_journal_entries.size()):
		discovery.append(_make_journal_entry_card())
	discovery.shuffle()

	GameState.planet_deck_data = discovery
	planet_deck.cards_remaining = discovery.size()
	deck.cards_remaining = GameState.player_deck.size()
	discard.cards_remaining = 0
	exile_pile.cards_remaining = 0

func _make_journal_card() -> CardData:
	# The board-card anchor for journal entries to stack onto.
	var cd := CardData.new()
	cd.card_name = "Journal"
	cd.card_types = ["journal"]
	return cd

func _make_alien_ship_card(ship_name: String) -> CardData:
	# Sits on the play space; the Contact card targets it via the "alien_ship" tag.
	var cd := CardData.new()
	cd.card_name = ship_name
	cd.card_types = ["alien_ship"]
	return cd

func _make_journal_entry_card() -> CardData:
	# Anonymous journal-entry slot for the discovery deck. The body is empty
	# here — text is assigned at reveal time from the sequential journal-entry
	# list, so entries stay in order even though the discovery deck is shuffled.
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
	_discover_one()
	for i in range(TURN_DRAW_COUNT):
		get_tree().create_timer(float(i) * DRAW_STAGGER_SEC).timeout.connect(_draw_one_card)
	var draw_total: float = float(TURN_DRAW_COUNT - 1) * DRAW_STAGGER_SEC + 0.05
	get_tree().create_timer(draw_total).timeout.connect(_clear_turn_transition)

func _discover_one() -> void:
	# Per-turn auto-discover: pop the top of the discovery deck and dispatch by
	# tag. "journal" entries stack onto the on-board Journal card; everything
	# else (planets, alien ships) settles into a free play-space cell.
	if GameState.planet_deck_data.is_empty():
		return
	var entry: CardData = GameState.planet_deck_data.pop_back()
	planet_deck.cards_remaining = GameState.planet_deck_data.size()
	if "journal" in entry.card_types:
		if _next_journal_index < _journal_entries.size():
			entry.body = _journal_entries[_next_journal_index]
			_next_journal_index += 1
		play_space.emit_card_onto_stack(entry, "journal")
	else:
		play_space.emit_card_to_cell(entry)

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
	#      leaf as a permanent visual (it does NOT enter discard).
	#   2. Threshold — `target_card` is null. The card was released above the
	#      hand threshold and goes to discard.
	if target_card != null:
		GameState.total_buildings_placed += 1
		play_space.attach_card_to_stack(card, target_card)
		card_slap_audio.play()
		return
	_send_card_to_discard(card)

func _send_card_to_discard(card: Card) -> void:
	GameState.player_discard.append(card.data)
	discard.cards_remaining = GameState.player_discard.size()
	_animate_play_to_pile(card, discard.global_position)

func _send_card_to_exile(card: Card) -> void:
	GameState.player_exile.append(card.data)
	exile_pile.cards_remaining = GameState.player_exile.size()
	_animate_play_to_pile(card, exile_pile.global_position)

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
	# Counter only needs to disambiguate simultaneous showcases. Reset
	# once the queue drains so it can't drift toward HOVER over a long run.
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
# Colony draft — every COLONY_DRAFT_INTERVAL turns of a colony's life, the
# player drafts one of COLONY_DRAFT_PACK_SIZE building cards into discard.
#
# Ageing happens at the start of the draw phase: every stacked card on the
# board ticks turns_alive by 1, and any colony hitting a multiple of the
# interval enqueues a draft request. Multiple colonies triggering the same
# turn queue up FIFO inside the Draft autoload.

func _age_buildings() -> void:
	for c in play_space.all_cards():
		# Roots are top-of-stack anchors (planet, journal, alien ship). Skip
		# those — only stacked cards age.
		if not (c.get_parent() is Card):
			continue
		c.turns_alive += 1
		if "colony" in c.card_types and c.turns_alive > 0 and c.turns_alive % COLONY_DRAFT_INTERVAL == 0:
			Draft.request(_colony_draft_pool(), COLONY_DRAFT_PACK_SIZE, _on_colony_card_drafted, discard.global_position)

func _colony_draft_pool() -> Array:
	# All cards in the library tagged `building`, plus Contact whenever an alien
	# ship is on the play space. Built fresh each draft so a ship that lands
	# between drafts becomes immediately reachable on the next colony tick.
	var pool: Array = []
	for c in CARD_LIBRARY.cards:
		if "building" in c.card_types:
			pool.append(c)
	if play_space.has_card_with_tag("alien_ship"):
		pool.append(CARD_CONTACT)
	return pool

func _on_colony_card_drafted(chosen: CardData) -> void:
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
# Reshuffle (discard → deck) cosmetic animation, reused verbatim.

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
