# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Godot 4.6 card-battler prototype (GDScript, 2D, GL Compatibility renderer). Single-player loop: each turn, the discovery deck reveals a planet/ship/journal entry into the play space, and the player drags cards from hand onto stacks built atop those board entities.

## Running

There is no build/test harness — the project runs in the Godot editor.

- Open in editor: `godot --path .` (or open `project.godot` from the Godot project manager).
- Run the main scene from the editor (F5). Main scene is `scenes/main.tscn`.
- In-game: `Space` ends turn, `Esc` closes the topmost pile viewer or quits.

There are no automated tests, no linter, and no headless run target wired up.

## Architecture

### Autoloads (singletons)

Configured in `project.godot` under `[autoload]`:

- **`GameState`** ([scripts/game_state.gd](scripts/game_state.gd)) — persistent run state: `player_deck`/`player_discard`/`player_exile` (arrays of `CardData`), `turn_number`, `total_buildings_placed`. The discovery pool of planets/stars (popped via Discover) lives on `main.gd::_discovery_pool`. Board state itself (which stacks live in which cells, what's stacked under what) is the play_space scene tree, NOT GameState. Walk play_space when you need to query the board.
- **`Draft`** ([scripts/draft.gd](scripts/draft.gd)) — reusable "pick 1 from N" modal flow. Callers post `request(pool, pack_size, on_picked, arc_target)`; requests serialize through a FIFO queue. Emits `started`/`finished` so callers can pause game input.

### One Card class, three visual variants

Every card in the game — hand cards, planets, stars, alien ships, journal anchors, journal entries, stacked buildings, resources — is a single `Card` ([scripts/card.gd](scripts/card.gd)) node instantiated from [scenes/card.tscn](scenes/card.tscn). The render is chosen at `configure()` time from the data's tags:

- **World cards** (`planet`/`star`/`journal`/`alien_ship` in `card_types`) — dark body, white name, optional sphere + (for planets) a type label showing the joined `planet_types`. These are the anchors at the top of every stack.
- **Resource cards** (`resource` in `card_types`) — teal body. Threshold-played; trigger synergy effects from cards in play.
- **Play cards** (everything else) — parchment body with a name + body-text panel. Cards in the player's hand, and stacked buildings on the board.

### Data flow

- `CardData` ([scripts/card_data.gd](scripts/card_data.gd)) — one `.tres` per card kind. Player cards live in `data/cards/`, resources in `data/resources/` (releases_on_threshold + a "resource" tag in `card_types`), synergy buildings in `data/synergy/`, planet defs in `data/planets/` (also CardData, with `card_types=["planet"]` and a `planet_types: Array[String]` populated; entries are folded into `card_types` at configure-time so `can_stack` rules can reference them). Aggregated by `data/card_library.tres` (CardLibrary, includes synergy/buildings/Discover/Contact/Colony) and `data/planet_library.tres` (PlanetLibrary, the authored slice of the discovery pool — main.gd tops it up procedurally).
- The starting deck is hard-coded in `main.gd` (`STARTING_DECK`), referencing `.tres` paths directly — no library lookup.
- `data/journal_entries.txt` — one journal-entry line per row. Lines are revealed in strict sequential order regardless of where the (anonymous, shuffled) journal-entry placeholders land in the discovery deck. See `_load_journal_entries` and `_make_journal_entry_card` in `main.gd`.

### Stacks are scene-tree parent chains

A stack is a chain of `Card` nodes along the scene tree: the chain root is a direct child of `PlaySpace/Stacks` and each successive card is a child of the previous one. Each child sits at local position `(0, _step)` so its body peeks out below its parent by `_step` pixels. Children inherit Node2D transforms, so dragging a stack root naturally moves the whole subtree — no manual "drag this list of children too" bookkeeping.

When a card in a stack is hovered, only that card's slot expands. The chain root tracks `_hover_card_in_chain`; the child of the hovered card gets `STEP_EXPANDED`, every other parent→child gap stays `STEP_COLLAPSED`. Cards below the expanded slot are pushed down rigidly via inherited transforms — they don't themselves expand. PlaySpace drives this by calling `set_chain_hover_target` on the chain root whenever the deepest card under the cursor changes.

### Tag-based stacking

The most important mechanic to internalize. Every Card carries two tag arrays:

- `card_types: Array[String]` — what this thing **is** (e.g. `["building", "colony"]`, `["planet"]`, `["journal"]`, `["alien_ship"]`, `["star"]`). For planets, the entries of `planet_types` are also folded in at `configure()` time so e.g. an Oceanic planet exposes `["planet", "Oceanic"]`.
- `can_stack: Array[String]` — what the **top of a target stack** must contain (AND) for this card to stack onto it. Empty = stacks on anything.
- `can_stack_any: Array[String]` — optional OR-gate alongside `can_stack`. When non-empty, the target's top must contain at least one of these. Used by buildings that work on any of several planet types (e.g. Aquifer Pump → Rocky / Oceanic / Ice).

Stack acceptance is `Card.can_accept_stack(can_stack, can_stack_any)` against `get_stack_top_card_types()` — the chain leaf's tags. Each newly stacked card's tags become the new leaf, so a `colony` stacked on a `planet` exposes `["building", "colony"]` to the next stacker.

A separate escape hatch: `CardData.releases_on_threshold` — when true, the card plays by being dragged above `Hand.play_threshold_y` rather than onto a stack. Bypasses `can_stack`.

### PlaySpace owns input

[scripts/play_space.gd](scripts/play_space.gd) is the sole input handler for the play area. It owns:

- The grid: `_occupied: Dictionary[Vector2i → Card]` mapping cell to chain-root card.
- Pan/zoom (within `ZOOM_REGION`).
- Hover/highlight on the chain root under the cursor.
- Board-stack drag: press a card → pick up its chain root → drag the whole subtree → drop. On drop, if the cursor is over a stack whose top accepts the dragged card's tags, the dragged subtree reparents under that stack's leaf via `Card.attach_below`. Otherwise the root snaps to the nearest empty cell.
- Spawn arcs from the planet deck (`emit_card_to_cell`, `emit_card_onto_stack`).

There are no per-card `Area2D`s. Hit testing walks each chain and returns the deepest descendant whose body rect contains the cursor.

Top-card-only pickup: clicking anywhere on a stack picks up the chain root (whole subtree comes with it). Picking up a sub-stack is not currently a feature.

Snap on drop, not mid-drag: while dragging, the stack floats freely; only on release does it commit to a cell or a stack target.

### Hand → board handoff

[scripts/hand.gd](scripts/hand.gd) owns the fan layout and hand-drag flow. While a hand card is being dragged, Hand asks `play_space.get_planet_under_cursor` for the topmost board card under the cursor and toggles its `targeted` highlight if `can_accept_stack` matches. On release, Hand emits `card_played(card, target)` which `main.gd::_on_card_played` dispatches: stack-play calls `play_space.attach_card_to_stack(card, target)` (the same final step a board drag uses on drop); threshold-release goes to discard.

Hand pauses itself when the play space is dragging (`play_space.is_dragging()`), so no two drags run simultaneously.

### Turn loop

`main.gd` runs a phase machine: `DRAW → PLAY → END_TURN`. Each draw phase calls `_age_buildings` (walks `play_space.all_cards()`, increments `turns_alive` on every stacked card; enqueues colony drafts every `COLONY_DRAFT_INTERVAL` turns and other-building drafts every `BUILDING_DRAFT_INTERVAL` turns), `_fly_in_journal_entry` (one journal entry stacks onto the Journal anchor, flown in from off-screen right), and rolls `ALIEN_SHIP_TURN_CHANCE` for a rare ship arrival. Planets/stars are NOT auto-revealed — the player has to play a Discover card, which pops the next entry from `_discovery_pool` and emits it onto a free cell.

Threshold-played cards (releases_on_threshold) take an extra dispatch step in `_on_card_played → _dispatch_play_effects`: the card's own `effect_id` runs ("draw N", "add_to_discard", "discover"), and for resources specifically every card on the board with a matching `triggers_on_play_tags` fires its effect too. This is how synergy buildings ("when you play food, draw 1") work. Buildings that should mint resources/cards on placement use `CardData.spawns_on_placement` — Colony spawns a Discover, every other building spawns its resource.

### Scene/script wiring

Every scene under `scenes/` has a script of the same name under `scripts/`. `main.tscn` is the root and uses `@onready` to grab `PlayerDeck`, `Hand`, `DiscardPile`, `ExilePile`, `PlaySpace`, `Hud`, `EndTurnButton`, `PileViewer` by node path. There is no on-screen discovery deck — new worlds and journal entries fly in from off-screen right (`PlaySpace._offscreen_origin`). `main.gd` is the only place these are wired together — child scripts only know about themselves and the few siblings whose references are injected (e.g. `hand.play_space = play_space`, `play_space.hand = hand`).

Pause coordination: when a modal opens (`PileViewer`, draft modal), `main.gd` sets `hand.input_paused = true` and `play_space.input_paused = true`. Both check this flag to drop hover state, cancel any in-flight drag, and skip per-frame interaction.

### Coordinate spaces

`PlaySpace` supports zoom and pan, so its children's `position` differs from `global_position`. Conventions:

- Cell math (`_cell_to_local`, `_nearest_empty_cell`, `find_empty_cell_in_view`) and stack-root positions live in **`PlaySpace`-local** coordinates — what survives zoom/pan correctly.
- Hit testing (`Card.contains_point_world`) takes a world point and uses the card's `to_local()` so the body rect comparison happens in the card's own frame.
- Emit-arc tweens fly card-backs in **global** coordinates (the planet deck lives outside `PlaySpace`), so `to_global(target_local)` is used at tween-seed time only.

## Conventions

- GDScript with `class_name` declarations on shared types (`Card`, `CardData`, `Hand`, `PlaySpace`, `Hud`, `Deck`, `DiscardPile`, `ExilePile`, `PileViewer`, `PlanetLibrary`, `CardLibrary`).
- Editor file is UTF-8 (`.editorconfig`). Tabs for indentation (Godot default).
- `.godot/` and `.claude/` are gitignored — don't commit cache or local tooling state.
