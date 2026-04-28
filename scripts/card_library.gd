class_name CardLibrary extends Resource

@export var cards: Array[CardData] = []

func get_by_type(t: int) -> CardData:
	for c in cards:
		if c.card_type == t:
			return c
	return null
