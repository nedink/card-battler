class_name EventCard extends Node2D

# Display-only event banner. Slides in from above the play space, holds for a
# beat, then slides back out. Effects are applied by main.gd; this is purely
# the visual.

const SLIDE_DURATION := 0.35
const HOLD_DURATION := 1.4
const BANNER_OFFSET_Y := -120.0   # Off-screen rest position (relative to anchor).
const BANNER_VISIBLE_Y := 60.0    # Below the HUD bar.

@onready var _body: Panel = $Body
@onready var _title: Label = $Body/Title
@onready var _description: Label = $Body/Description

func _ready() -> void:
	position.y = BANNER_OFFSET_Y
	visible = false

func show_event(title: String, description: String) -> void:
	_title.text = title
	_description.text = description
	visible = true
	position.y = BANNER_OFFSET_Y
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", BANNER_VISIBLE_Y, SLIDE_DURATION)
	tween.tween_interval(HOLD_DURATION)
	tween.tween_property(self, "position:y", BANNER_OFFSET_Y, SLIDE_DURATION) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween.tween_callback(func(): visible = false)
