extends Node2D

# Game flow controller for the Planetary Civilization Tycoon. Owns:
#   - turn-phase state machine (EVENT → INCOME → DRAW → PLAY → END_TURN)
#   - card play dispatch (Discover, Build_*, Trade Route)
#   - trade-route selection mode (modal click-two-planets overlay)
#   - lose condition + score calculation
#
# All persistent data lives in `GameState` (autoload). This script is just
# orchestration and animation timing.

const CARD_SCENE := preload("res://scenes/card.tscn")
const CARD_BACK_SCENE := preload("res://scenes/card_back.tscn")

const TIME_SCALE := 1.0

const TURN_DRAW_COUNT := 5
const DRAW_STAGGER_SEC := 0.12
const DISCARD_STAGGER_SEC := 0.06

const RESHUFFLE_STAGGER := 0.05
const RESHUFFLE_FLY_DURATION := 0.5
const RESHUFFLE_MAX_VISIBLE := 8
const RESHUFFLE_ARC_PEAK := 90.0
const RESHUFFLE_Z := -1

const SHOWCASE_SLOT_SPACING := 110.0
const SHOWCASE_Z_BASE := 1000

# Initial resources.
const STARTING_CREDITS := 3
const STARTING_RESEARCH := 0
const STARTING_ENERGY := 0

# Per-turn random event roll. 0 disables events; 1.0 forces one every turn.
const EVENT_CHANCE := 0.5

# Score weights.
# score = turn_number * total_buildings_placed

# Card definitions live in data/card_library.tres — edit cards/costs/text in the
# inspector, not here. CardData entries are looked up by Card.CardType enum.
const CARD_LIBRARY: CardLibrary = preload("res://data/card_library.tres")

var STARTING_DECK := [
	Card.CardType.DISCOVER,
	Card.CardType.BUILD_COLONY,
	Card.CardType.BUILD_FACTORY,
	Card.CardType.BUILD_LAB,
	Card.CardType.BUILD_POWER_PLANT,
]

# Planet pool lives in data/planet_library.tres — add/edit planet defs there.
const PLANET_LIBRARY: PlanetLibrary = preload("res://data/planet_library.tres")

const HOMEWORLD_POSITION := Vector2(540, 220)

enum Phase { EVENT, INCOME, DRAW, PLAY, END_TURN }

@onready var deck: Deck = $PlayerDeck
@onready var hand: Hand = $Hand
@onready var discard: DiscardPile = $DiscardPile
@onready var exile_pile: ExilePile = $ExilePile
@onready var planet_deck: Deck = $PlanetDeck
@onready var play_space: PlaySpace = $PlaySpace
@onready var hud: Hud = $Hud
@onready var event_banner: EventCard = $EventCard
@onready var end_turn_button: Button = $EndTurnButton
@onready var selection_overlay: ColorRect = $SelectionOverlay
@onready var selection_label: Label = $SelectionOverlay/SelectionLabel
@onready var game_over_overlay: ColorRect = $GameOverOverlay
@onready var game_over_label: Label = $GameOverOverlay/GameOverLabel
# Cast required because the instanced scene's static root type is `Control`
# (the script class_name doesn't propagate through `$NodePath` lookup).
@onready var pile_viewer: PileViewer = $PileViewer as PileViewer

var _showcasing: Array[Card] = []
var _play_counter: int = 0
var _turn_transitioning: bool = false
var _next_planet_id: int = 0

# Trade route mode state. Active while the player is selecting two planets.
var _trade_route_mode: bool = false
var _trade_route_planets: Array = []
# Cached card consumed by trade route mode — refunded if user cancels.
var _trade_route_pending_card: Card = null

var _game_over: bool = false

func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	hand.card_played.connect(_on_card_played)
	hand.can_play_card = _can_play_card
	hand.play_space = play_space
	play_space.hand = hand
	GameState.resources_changed.connect(_update_hand_affordability)
	play_space.planet_clicked.connect(_on_planet_clicked)
	play_space.set_planet_deck_position(planet_deck.global_position)
	end_turn_button.pressed.connect(_on_end_turn)
	# Pile-viewer wiring: clicking any pile pops a viewer with its contents.
	deck.pile_clicked.connect(_open_draw_pile_viewer)
	discard.pile_clicked.connect(_open_discard_pile_viewer)
	exile_pile.pile_clicked.connect(_open_exile_pile_viewer)
	pile_viewer.dismissed.connect(_on_pile_viewer_dismissed)
	selection_overlay.visible = false
	if game_over_overlay != null:
		game_over_overlay.visible = false
	_init_game_state()
	_start_first_turn()

func _init_game_state() -> void:
	GameState.credits = STARTING_CREDITS
	GameState.research = STARTING_RESEARCH
	GameState.energy = STARTING_ENERGY
	GameState.turn_number = 1
	GameState.planets.clear()
	GameState.trade_routes.clear()
	GameState.player_discard.clear()
	GameState.player_exile.clear()
	GameState.total_buildings_placed = 0
	GameState.reset_per_turn_flags()

	# Player deck: shuffled card-type list. Each entry is just the enum value;
	# CARD_LIBRARY supplies the rest at instantiation time.
	GameState.player_deck = STARTING_DECK.duplicate()
	GameState.player_deck.shuffle()

	# Planet deck: shuffled list of PlanetData. The homeworld is taken out and
	# placed immediately; the remaining 8 stay face-down.
	var pool: Array = []
	for p in PLANET_LIBRARY.planets:
		pool.append(_make_planet_data(p.planet_name, p.planet_type))
	pool.shuffle()
	# Homeworld: pull a random rocky planet to feel grounded; fall back to any.
	var homeworld = null
	for i in range(pool.size()):
		if pool[i].planet_type == "Rocky":
			homeworld = pool[i]
			pool.remove_at(i)
			break
	if homeworld == null:
		homeworld = pool.pop_front()
	homeworld.planet_name = "Homeworld"
	GameState.planets.append(homeworld)
	play_space.place_planet_immediate(homeworld, HOMEWORLD_POSITION)

	GameState.planet_deck_data = pool
	planet_deck.cards_remaining = pool.size()
	deck.cards_remaining = GameState.player_deck.size()
	discard.cards_remaining = 0
	exile_pile.cards_remaining = 0

func _make_planet_data(p_name: String, p_type: String):
	var pd = GameState.PlanetData.new(_next_planet_id, p_name, p_type, Vector2.ZERO)
	_next_planet_id += 1
	return pd

func _start_first_turn() -> void:
	# First turn skips EVENT to give the player one clean turn.
	_run_income_phase()
	_run_draw_phase()
	_set_phase(Phase.PLAY)

# ---------------------------------------------------------------------------
# Phase machine

func _set_phase(p: int) -> void:
	GameState.turn_phase_changed.emit(p)

func _on_end_turn() -> void:
	if _turn_transitioning or _trade_route_mode or hand.is_dragging() or _game_over:
		return
	_turn_transitioning = true
	_run_end_turn_phase()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			# Esc cascades from most-modal to least: viewer first, trade-route
			# selection next, then quit.
			if pile_viewer.is_open():
				pile_viewer.hide_viewer()
			elif _trade_route_mode:
				_cancel_trade_route_mode()
			else:
				get_tree().quit()
		elif event.keycode == KEY_SPACE:
			_on_end_turn()

# ---------------------------------------------------------------------------
# EVENT phase

func _run_event_phase() -> void:
	_set_phase(Phase.EVENT)
	if randf() >= EVENT_CHANCE:
		return
	var roll := randi() % 4
	match roll:
		0: _trigger_meteor_strike()
		1: _trigger_plague()
		2: _trigger_resource_shortage()
		3: _trigger_solar_flare()

func _trigger_meteor_strike() -> void:
	# Destroy one random building from a random planet that has buildings.
	var candidates := []
	for p in GameState.planets:
		if p.buildings.size() > 0:
			candidates.append(p)
	if candidates.is_empty():
		event_banner.show_event("Meteor Strike", "A meteor struck — but found no infrastructure to harm.")
		return
	var planet = candidates.pick_random()
	var idx: int = randi() % int(planet.buildings.size())
	var destroyed = planet.buildings[idx]
	planet.buildings.remove_at(idx)
	# Also free the visual card sitting in the destroyed slot, then re-tween
	# remaining building visuals up to fill the gap.
	for pc in play_space.get_planets():
		if pc.data == planet:
			pc.remove_building_visual_at(idx)
			pc.refresh_from_data()
			break
	event_banner.show_event("Meteor Strike",
		"%s destroyed on %s." % [destroyed.building_type, planet.planet_name])

func _trigger_plague() -> void:
	if GameState.planets.is_empty():
		return
	var planet = GameState.planets.pick_random()
	GameState.plagued_planet_id = planet.id
	event_banner.show_event("Plague",
		"%s earns no Credits next turn." % planet.planet_name)

func _trigger_resource_shortage() -> void:
	GameState.credits_halved_this_turn = true
	event_banner.show_event("Resource Shortage",
		"Credits production is halved next turn.")

func _trigger_solar_flare() -> void:
	GameState.trade_routes_blocked_this_turn = true
	for route in GameState.trade_routes:
		route.blocked = true
	event_banner.show_event("Solar Flare",
		"Trade routes are blocked next turn.")

# ---------------------------------------------------------------------------
# INCOME phase — apply per-turn resource generation from buildings + routes

func _run_income_phase() -> void:
	_set_phase(Phase.INCOME)
	var cred_in := 0
	var res_in := 0
	var en_in := 0
	for p in GameState.planets:
		var planet_credits := 0
		var planet_research := 0
		var planet_energy := 0
		for b in p.buildings:
			var def: Dictionary = GameState.BUILDING_DEFS[b.building_type]
			planet_credits += int(def["credits"])
			planet_research += int(def["research"])
			planet_energy += int(def["energy"])
		# Plague nullifies Credits from the affected planet for this one turn.
		if p.id == GameState.plagued_planet_id:
			planet_credits = 0
		cred_in += planet_credits
		res_in += planet_research
		en_in += planet_energy
	# Trade routes: +1 Credits to each connected planet (so +2 total per route),
	# unless blocked or one of the planets is plagued (it earns 0).
	for route in GameState.trade_routes:
		if route.blocked:
			continue
		var pa = GameState.find_planet_by_id(route.planet_a_id)
		var pb = GameState.find_planet_by_id(route.planet_b_id)
		if pa == null or pb == null:
			continue
		if pa.id != GameState.plagued_planet_id:
			cred_in += 1
		if pb.id != GameState.plagued_planet_id:
			cred_in += 1
	if GameState.credits_halved_this_turn:
		cred_in = cred_in / 2
	GameState.credits += cred_in
	GameState.research += res_in
	GameState.energy = maxi(0, GameState.energy + en_in)
	# Per-turn flags reset AFTER they've been applied this income phase, so
	# the next event phase starts with a clean slate.
	GameState.reset_per_turn_flags()

# ---------------------------------------------------------------------------
# DRAW phase

func _run_draw_phase() -> void:
	_set_phase(Phase.DRAW)
	for i in range(TURN_DRAW_COUNT):
		get_tree().create_timer(float(i) * DRAW_STAGGER_SEC).timeout.connect(_draw_one_card)
	var draw_total: float = float(TURN_DRAW_COUNT - 1) * DRAW_STAGGER_SEC + 0.05
	get_tree().create_timer(draw_total).timeout.connect(_clear_turn_transition)

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
		_animate_reshuffle(recycled)
	if GameState.player_deck.is_empty():
		return
	var card_type: int = GameState.player_deck.pop_back()
	deck.cards_remaining = GameState.player_deck.size()
	var def: CardData = CARD_LIBRARY.get_by_type(card_type)
	var card: Card = CARD_SCENE.instantiate()
	card.configure(def.card_name, card_type, def.cost, def.resource, def.body)
	hand.add_card(card, deck.global_position)
	card.set_affordable(GameState.can_afford(card.cost_dict()))

# ---------------------------------------------------------------------------
# END_TURN phase — discard hand, advance turn counter, run next EVENT/INCOME/DRAW

func _run_end_turn_phase() -> void:
	_set_phase(Phase.END_TURN)
	hand.clear_hover()
	var hand_cards := hand.cards.duplicate()
	# Logically place cards into discard immediately so the deck/discard
	# counters stay correct even mid-flight.
	for c in hand_cards:
		GameState.player_discard.append(c.card_type)
	discard.cards_remaining += hand_cards.size()
	hand.cards.clear()
	hand.layout()
	var delay := 0.0
	for card in hand_cards:
		get_tree().create_timer(delay).timeout.connect(_discard_one.bind(card))
		delay += DISCARD_STAGGER_SEC

	GameState.turn_number += 1
	hud.set_turn(GameState.turn_number)
	_run_event_phase()
	_run_income_phase()
	_run_draw_phase()
	_check_game_over()

func _discard_one(card: Card) -> void:
	card.fly_finished.connect(_on_card_fly_finished, CONNECT_ONE_SHOT)
	card.discard_fly(discard.global_position)

# ---------------------------------------------------------------------------
# Card play dispatch

func _can_play_card(card: Card) -> bool:
	return GameState.can_afford(card.cost_dict())

func _update_hand_affordability() -> void:
	for card in hand.cards:
		card.set_affordable(GameState.can_afford(card.cost_dict()))

func _on_card_played(card: Card, target_planet) -> void:
	# Pay cost first so the affordability check we already passed is consistent.
	GameState.deduct(card.cost_dict())

	# Apply the card's effect, then send it to the right pile. Discover cards
	# are exiled (removed from the deck for the rest of the run); everything
	# else recycles through the discard pile back into the deck.
	match card.card_type:
		Card.CardType.DISCOVER:
			_apply_discover()
			#_send_card_to_exile(card)
			_send_card_to_discard(card)
		Card.CardType.BUILD_COLONY:
			if _apply_build("Colony", target_planet):
				_send_card_to_building_slot(card, target_planet)
			else:
				_send_card_to_discard(card)
		Card.CardType.BUILD_FACTORY:
			if _apply_build("Factory", target_planet):
				_send_card_to_building_slot(card, target_planet)
			else:
				_send_card_to_discard(card)
		Card.CardType.BUILD_LAB:
			if _apply_build("Lab", target_planet):
				_send_card_to_building_slot(card, target_planet)
			else:
				_send_card_to_discard(card)
		Card.CardType.BUILD_POWER_PLANT:
			if _apply_build("Power Plant", target_planet):
				_send_card_to_building_slot(card, target_planet)
			else:
				_send_card_to_discard(card)
		Card.CardType.TRADE_ROUTE:
			# Trade route enters selection mode. The card is held aside (its
			# pile destination is decided after the player picks two planets,
			# or it's refunded to the hand on cancel).
			_trade_route_pending_card = card
			card.visible = false
			_begin_trade_route_mode()

func _send_card_to_discard(card: Card) -> void:
	GameState.player_discard.append(card.card_type)
	discard.cards_remaining = GameState.player_discard.size()
	_animate_play_to_pile(card, discard.global_position)

func _send_card_to_exile(card: Card) -> void:
	GameState.player_exile.append(card.card_type)
	exile_pile.cards_remaining = GameState.player_exile.size()
	_animate_play_to_pile(card, exile_pile.global_position)

func _send_card_to_building_slot(card: Card, target_planet) -> void:
	# The played card itself becomes the planet's building visual — handed
	# off to the planet, which reparents it and tweens it into a stacked
	# slot. It does NOT go into the discard pile (it's consumed by the
	# building) — meteor strikes destroy the visual outright.
	target_planet.attach_building_card(card)

func _animate_play_to_pile(card: Card, target_world_pos: Vector2) -> void:
	_showcasing.append(card)
	_play_counter += 1
	card.z_index = SHOWCASE_Z_BASE + _play_counter
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

func _on_card_fly_finished(card: Card) -> void:
	card.queue_free()

func _showcase_position(index: int, total: int) -> Vector2:
	var center := get_viewport_rect().size * 0.5
	if total <= 1:
		return center
	var offset_x := (float(index) - (float(total) - 1.0) * 0.5) * SHOWCASE_SLOT_SPACING
	return center + Vector2(offset_x, 0.0)

# ---------------------------------------------------------------------------
# Card effect appliers

func _apply_discover() -> void:
	if GameState.planet_deck_data.is_empty():
		return
	var pd = GameState.planet_deck_data.pop_back()
	planet_deck.cards_remaining = GameState.planet_deck_data.size()
	GameState.planets.append(pd)
	play_space.emit_next_planet(pd)

func _apply_build(building_type: String, target_planet) -> bool:
	# Returns true if the building was actually added. Caller uses this to
	# decide whether the played card becomes a building visual or, in the
	# fallback case (target invalid / planet full), falls back to the discard
	# pile so the cost isn't silently lost.
	if target_planet == null or target_planet.data == null:
		return false
	var planet = target_planet.data
	if planet.buildings.size() >= GameState.MAX_BUILDINGS_PER_PLANET:
		return false
	var b = GameState.BuildingData.new(building_type)
	planet.buildings.append(b)
	GameState.total_buildings_placed += 1
	target_planet.refresh_from_data()
	return true

# ---------------------------------------------------------------------------
# Trade route mode

func _begin_trade_route_mode() -> void:
	_trade_route_mode = true
	_trade_route_planets.clear()
	selection_overlay.visible = true
	selection_label.text = "Select 2 planets to connect (Esc to cancel)"
	# Block further plays while the modal is active.
	hand.can_play_card = func(_c): return false

func _on_planet_clicked(planet) -> void:
	if not _trade_route_mode:
		return
	if planet in _trade_route_planets:
		return
	# Disallow connecting two planets already linked.
	for route in GameState.trade_routes:
		if (route.planet_a_id == planet.data.id and _trade_route_planets.size() == 1 \
				and route.planet_b_id == _trade_route_planets[0].data.id) \
			or (route.planet_b_id == planet.data.id and _trade_route_planets.size() == 1 \
				and route.planet_a_id == _trade_route_planets[0].data.id):
			return
	planet.set_selected(true)
	_trade_route_planets.append(planet)
	if _trade_route_planets.size() == 2:
		_finalize_trade_route()

func _finalize_trade_route() -> void:
	var pa = _trade_route_planets[0]
	var pb = _trade_route_planets[1]
	var data = GameState.TradeRouteData.new(pa.data.id, pb.data.id)
	GameState.trade_routes.append(data)
	play_space.add_trade_route_visual(pa, pb, data)
	pa.set_selected(false)
	pb.set_selected(false)
	# Send the held card to the discard pile (Trade Route is reusable, not exiled).
	var card := _trade_route_pending_card
	_trade_route_pending_card = null
	if card != null:
		card.visible = true
		_send_card_to_discard(card)
	_exit_trade_route_mode()

func _cancel_trade_route_mode() -> void:
	# Refund the card cost and return the card to the hand. The card was never
	# put in any pile yet — it's been held in _trade_route_pending_card while
	# the modal is up — so there's nothing to remove from discard/exile here.
	for p in _trade_route_planets:
		p.set_selected(false)
	_trade_route_planets.clear()
	if _trade_route_pending_card != null:
		var card := _trade_route_pending_card
		_trade_route_pending_card = null
		GameState.credits += int(card.cost_dict().get("credits", 0))
		GameState.research += int(card.cost_dict().get("research", 0))
		GameState.energy += int(card.cost_dict().get("energy", 0))
		card.visible = true
		hand.cards.append(card)
		# Card was left in DRAGGING state when the play emitted. Return it to
		# IDLE so _process eases it back to its rest pose in the fan.
		card.end_drag_return()
		hand.layout()
		card.set_affordable(GameState.can_afford(card.cost_dict()))
	_exit_trade_route_mode()

func _exit_trade_route_mode() -> void:
	_trade_route_mode = false
	selection_overlay.visible = false
	hand.can_play_card = _can_play_card

# ---------------------------------------------------------------------------
# Game-over check

func _check_game_over() -> void:
	if _game_over:
		return
	if GameState.building_count() == 0 and GameState.credits == 0:
		_game_over = true
		var score := GameState.turn_number * GameState.total_buildings_placed
		GameState.game_over_triggered.emit(score)
		if game_over_overlay != null:
			game_over_overlay.visible = true
			game_over_label.text = "GAME OVER\nTurns: %d\nBuildings placed: %d\nScore: %d" \
				% [GameState.turn_number, GameState.total_buildings_placed, score]

# ---------------------------------------------------------------------------
# Pile viewers (draw/discard/exile)

func _open_draw_pile_viewer() -> void:
	_open_pile_viewer("Draw Pile", GameState.player_deck)

func _open_discard_pile_viewer() -> void:
	_open_pile_viewer("Discard Pile", GameState.player_discard)

func _open_exile_pile_viewer() -> void:
	_open_pile_viewer("Exile Pile", GameState.player_exile)

func _open_pile_viewer(title: String, card_types: Array) -> void:
	# Build per-card def dicts the viewer can render with card.configure().
	# The viewer sorts alphabetically by name internally so the deck order
	# isn't leaked through this UI.
	var entries: Array = []
	for ct in card_types:
		var def: CardData = CARD_LIBRARY.get_by_type(ct)
		entries.append({
			"name": def.card_name,
			"type": ct,
			"cost": def.cost,
			"resource": def.resource,
			"body": def.body,
		})
	hand.input_paused = true
	pile_viewer.show_pile(title, entries)

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
	back.z_index = RESHUFFLE_Z

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
