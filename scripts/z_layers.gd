class_name ZLayers extends RefCounted

# Single source of truth for every z_index value used in the game.
#
# The game now spans three CanvasLayers, and z_index only fights between
# nodes on the same layer. That lets each layer's band layout stay tight.
#
# Default layer (world, layer=0):
#
#   BG               =  -10   Static background ColorRect.
#   RESHUFFLE        =   -1   Discard→deck card-back arc (renders behind board).
#   ARC_BACK         =   50   Planet-deck→cell card-back during emit-arc anim.
#   NATURAL_RANGE    = ±1000  Board stack roots, clamped to cell y so
#                             southerly stacks render in front of northerly
#                             ones. Stack chain children inherit z relatively
#                             via STACK_CHILD_OFFSET, so the whole chain rides
#                             with the root.
#   SHOWCASE_BASE    = 1500   Cards mid play→pile arc; offset by an ordinal
#                             so simultaneous showcasing cards layer in
#                             play order. Sits above NATURAL_RANGE so a
#                             showcasing card draws above any board stack.
#   HOVER            = 2000   Hover-lifted board card. Above NATURAL_RANGE +
#                             showcase headroom.
#   DRAG             = 2500   Actively-dragged board card. Above HOVER so
#                             the dragged stack always wins.
#   ARC_BUMP         =  +500  Added to a flying card's z when it enters its
#                             arc phase, so the arc reads above any peer
#                             still in its showcase pose.
#   STACK_CHILD_OFFSET = 1    Each chain child sits +1 above its parent
#                             (z_as_relative=true), so newer-on-top is free.
#
# HandLayer (layer=5): structurally above world, so values just need to
# distinguish hand cards from each other.
#
#   HAND_FAN_BASE    =   10   Hand cards in fan order (HAND_FAN_BASE + idx).
#                             Above 0 so freshly-drawn cards layer above end-
#                             of-turn discards still arcing toward the pile
#                             (those reset to z=0 in Card.discard_fly).
#   HAND_HOVER       =  100   Hover-lifted hand card.
#   HAND_DRAG        =  200   Actively-dragged hand card.
#
# Modal CanvasLayers escape the world entirely:
#   PileViewer  layer=10
#   DraftModal  layer=20
#
# GODOT_Z_CAP = 4096 — Godot's CanvasItem z_index hard limit. Values outside
# ±4096 are silently rejected, so we clamp anything that might combine into
# the ceiling (e.g. DRAG + ARC_BUMP).

const BG := -10
const RESHUFFLE := -1
const ARC_BACK := 50
const NATURAL_RANGE := 1000
const SHOWCASE_BASE := 1500
const HOVER := 2000
const DRAG := 2500
const ARC_BUMP := 500
const GODOT_Z_CAP := 4096
const STACK_CHILD_OFFSET := 1

const HAND_FAN_BASE := 10
const HAND_HOVER := 100
const HAND_DRAG := 200
