class_name CardLibrary extends Resource

# Manifest of every CardData in the game. Currently used as a registry
# reference; the deck stores CardData refs directly so no lookup is needed.

@export var cards: Array[CardData] = []
