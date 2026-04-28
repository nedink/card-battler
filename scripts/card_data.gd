class_name CardData extends Resource

# Definition for one card type. The `card_type` enum is the join key with
# effect-dispatch logic in main.gd; do not reorder Card.CardType.

@export var card_type: Card.CardType = Card.CardType.DISCOVER
@export var card_name: String = ""
@export var cost: int = 0
@export var resource: String = "credits"  # "credits" | "research"
@export_multiline var body: String = ""
