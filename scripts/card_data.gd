class_name CardData extends Resource

# Definition for one card type. The tag system in `card_types` / `can_stack`
# drives card-to-card interactions: a card C can be played on top of a stack
# whose topmost card T satisfies T.card_types ⊇ C.can_stack. An empty
# can_stack means "stackable on anything". `releases_on_threshold` is an
# escape hatch for cards that play via the snappy drag-up-and-release flow
# (e.g. Discover); when true, it bypasses the can_stack check entirely.

@export var card_name: String = ""
@export_multiline var body: String = ""

# Tags identifying this card. Used by other cards' can_stack rules and (later)
# to dispatch behavior — e.g. "building" might guarantee an on_destroy hook.
@export var card_types: Array[String] = []

# Tags the top card of a target stack must contain for this card to stack on
# it. Empty = stack on anything.
@export var can_stack: Array[String] = []

# When true, the card plays by being released above the hand's threshold line
# instead of by being dragged onto a stack. Takes precedence over can_stack.
@export var releases_on_threshold: bool = false
