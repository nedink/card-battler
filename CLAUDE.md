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

- **`GameState`** ([scripts/game_state.gd](scripts/game_state.gd)) — persistent run state: `player_deck`/`player_discard`/`player_exile` (arrays of `CardData`), `planet_deck_data` (the discovery deck — Array of `CardData`), `turn_number`, `total_buildings_placed`. Board state itself (which stacks live in which cells, what's stacked under what) is the play_space scene tree, NOT GameState. Walk play_space when you need to query the board.
- **`Draft`** ([scripts/draft.gd](scripts/draft.gd)) — reusable "pick 1 from N" modal flow. Callers post `request(pool, pack_size, on_picked, arc_target)`; requests serialize through a FIFO queue. Emits `started`/`finished` so callers can pause game input.

### One Card class, two visual variants

Every card in the game — hand cards, planets, alien ships, journal anchors, journal entries, stacked buildings — is a single `Card` ([scripts/card.gd](scripts/card.gd)) node instantiated from [scenes/card.tscn](scenes/card.tscn). The render is chosen at `configure()` time from the data's tags:

- **World cards** (`planet`/`journal`/`alien_ship` in `card_types`) — dark body, white name, optional sphere + type label for actual planets. These are the anchors at the top of every stack.
- **Play cards** (everything else) — parchment body with a name + body-text panel. Cards in the player's hand, and stacked buildings on the board.

### Data flow

- `CardData` ([scripts/card_data.gd](scripts/card_data.gd)) — one `.tres` per card kind. Player cards live in `data/cards/`, planet defs in `data/planets/` (also CardData, with `card_types=["planet"]` and `planet_type` populated). Aggregated by `data/card_library.tres` (CardLibrary) and `data/planet_library.tres` (PlanetLibrary, just `Array[CardData]`).
- The starting deck is hard-coded in `main.gd` (`STARTING_DECK`), referencing `.tres` paths directly — no library lookup.
- `data/journal_entries.txt` — one journal-entry line per row. Lines are revealed in strict sequential order regardless of where the (anonymous, shuffled) journal-entry placeholders land in the discovery deck. See `_load_journal_entries` and `_make_journal_entry_card` in `main.gd`.

### Stacks are scene-tree parent chains

A stack is a chain of `Card` nodes along the scene tree: the chain root is a direct child of `PlaySpace/Stacks` and each successive card is a child of the previous one. Each child sits at local position `(0, _step)` so its body peeks out below its parent by `_step` pixels. Children inherit Node2D transforms, so dragging a stack root naturally moves the whole subtree — no manual "drag this list of children too" bookkeeping.

When a card is hovered, the chain root expands the peek across all descendants (`_propagate_step`) so the player can read each card.

### Tag-based stacking

The most important mechanic to internalize. Every Card carries two tag arrays:

- `card_types: Array[String]` — what this thing **is** (e.g. `["building", "colony"]`, `["planet"]`, `["journal"]`, `["alien_ship"]`).
- `can_stack: Array[String]` — what the **top of a target stack** must contain for this card to stack onto it. Empty = stacks on anything.

Stack acceptance is `Card.can_accept_stack(can_stack)` against `get_stack_top_card_types()` — the chain leaf's tags. Each newly stacked card's tags become the new leaf, so a `colony` stacked on a `planet` exposes `["building", "colony"]` to the next stacker.

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

`main.gd` runs a phase machine: `DRAW → PLAY → END_TURN`. Each draw phase calls `_age_buildings` (walks `play_space.all_cards()`, increments `turns_alive` on every stacked card, enqueues colony drafts on the every-`COLONY_DRAFT_INTERVAL`-turns boundary) and `_discover_one` (pops from `GameState.planet_deck_data` — `journal`-tagged entries stack onto the on-board Journal anchor; everything else settles into a free cell).

### Scene/script wiring

Every scene under `scenes/` has a script of the same name under `scripts/`. `main.tscn` is the root and uses `@onready` to grab `PlayerDeck`, `Hand`, `DiscardPile`, `ExilePile`, `PlanetDeck`, `PlaySpace`, `Hud`, `EndTurnButton`, `PileViewer` by node path. `main.gd` is the only place these are wired together — child scripts only know about themselves and the few siblings whose references are injected (e.g. `hand.play_space = play_space`, `play_space.hand = hand`).

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
