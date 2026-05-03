class_name ZLayers extends RefCounted

# Single source of truth for every z_index value used in the game. Keep
# this in sync with the band layout below — each band leaves headroom for
# the bands above it so a card lifted by one rule never gets occluded by
# another rule firing below.
#
# Band layout (low → high):
#
#   BG               =  -10   Static background ColorRect.
#   RESHUFFLE        =   -1   Discard→deck card-back arc (renders behind board).
#   ARC_BACK         =   50   Planet-deck→cell card-back during emit-arc anim.
#   HAND_FAN_BASE    =   10   Hand cards in fan order (HAND_FAN_BASE + idx).
#                             Above 0 so freshly-drawn cards layer above end-
#                             of-turn discards still arcing toward the pile
#                             (those reset to z=0 in Card.discard_fly).
#   NATURAL_RANGE    = ±3000  Board stack roots, clamped to cell y so
#                             southerly stacks render in front of northerly
#                             ones. Stack chain children inherit z relatively
#                             via STACK_CHILD_OFFSET, so the whole chain rides
#                             with the root.
#   SHOWCASE_BASE    = 1000   Cards mid play→pile arc; offset by an ordinal
#                             so simultaneous showcasing cards layer in
#                             play order. Sits inside NATURAL_RANGE so a
#                             showcasing card draws above any board stack.
#   HOVER            = 3500   Hover-lifted card (hand OR board). Must beat
#                             the upper edge of NATURAL_RANGE.
#   DRAG             = 4000   Actively-dragged card (hand OR board). Above
#                             HOVER so the dragged stack always wins.
#   ARC_BUMP         = +1000  Added to a flying card's z when it enters its
#                             arc phase, so the arc reads above any peer
#                             still in its showcase pose.
#   GODOT_Z_CAP      = 4096   Godot's CanvasItem z_index hard limit. Values
#                             outside ±4096 are silently rejected, so we
#                             clamp anything that might combine into the
#                             ceiling (e.g. DRAG + ARC_BUMP).
#   STACK_CHILD_OFFSET = 1    Each chain child sits +1 above its parent
#                             (z_as_relative=true), so newer-on-top is free.
#
# Modal overlays (PileViewer, DraftModal) escape this z-space entirely by
# living on their own CanvasLayers — no number here can fight them.

const BG := -10
const RESHUFFLE := -1
const ARC_BACK := 50
const HAND_FAN_BASE := 10
const NATURAL_RANGE := 3000
const SHOWCASE_BASE := 1000
const HOVER := 3500
const DRAG := 4000
const ARC_BUMP := 1000
const GODOT_Z_CAP := 4096
const STACK_CHILD_OFFSET := 1
