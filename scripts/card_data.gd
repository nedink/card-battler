class_name CardData extends Resource

# Definition for one card type. The tag system in `card_types` / `can_stack`
# drives card-to-card interactions: a card C can be played on top of a stack
# whose topmost card T satisfies T.card_types ⊇ C.can_stack. An empty
# can_stack means "stackable on anything". `releases_on_threshold` is an
# escape hatch for cards that play via the snappy drag-up-and-release flow
# (e.g. Discover, resources); when true, it bypasses the can_stack check
# entirely.

@export var card_name: String = ""
@export_multiline var body: String = ""

# Tags identifying this card. Used by other cards' can_stack rules and (later)
# to dispatch behavior — e.g. "building" might guarantee an on_destroy hook.
@export var card_types: Array[String] = []

# Tags the top card of a target stack must contain (AND) for this card to
# stack on it. Empty = stack on anything.
@export var can_stack: Array[String] = []

# Optional OR-gate alongside can_stack. When non-empty, the target stack's
# top must contain AT LEAST ONE of these tags. Used by buildings that work
# on any of several planet types (e.g. Aquifer Pump on Rocky / Oceanic / Ice).
@export var can_stack_any: Array[String] = []

# When true, the card plays by being released above the hand's threshold line
# instead of by being dragged onto a stack. Takes precedence over can_stack.
@export var releases_on_threshold: bool = false

# Only meaningful for cards with the "planet" tag — drives the sphere/body
# tint and the type label. Each entry also gets folded into card_types at
# configure() time so building can_stack rules can require specific types
# (e.g. ["planet", "Oceanic"]).
@export var planet_types: Array[String] = []

# Threshold-played cards with this flag flag exile themselves on play instead
# of going to discard. Used by Discover.
@export var exiles_on_play: bool = false

# When this card is placed (stacked onto something), each entry is appended
# to the player's discard pile. Used by buildings to mint a resource on
# placement, and by Colony to mint a Discover.
@export var spawns_on_placement: Array[CardData] = []

# Synergy hook. When ANY threshold-played card carries any of these tags,
# this card's effect_id fires. Empty = never triggered.
@export var triggers_on_play_tags: Array[String] = []

# Effect dispatch. effect_id is a string key looked up by main._dispatch_effect.
# effect_amount and effect_payload parameterise the effect.
@export var effect_id: String = ""
@export var effect_amount: int = 1
@export var effect_payload: CardData = null
