class_name InputTuning
extends RefCounted
## Every number that decides how the hands, the stylus and the menu feel, in one place. Distances are metres, times seconds. The other
## scripts take their constants from here (or alias them), so a tuning pass is a one-file change; tests/test_hand_input.gd pins the
## pinch ones. docs/INTERACTIONS.md describes what each one does.

# ------------------------------------------------------------------------------------------------ pinch (HandInput)
const PINCH_ON := 0.9                      # strength that counts as pinched...
const PINCH_OFF := 0.6                     # ...and the lower one that releases it
const CLOSE_START := 0.35                  # the fingers are closing: hold the ray
const CLOSE_CANCEL := 0.2                  # the fingers are apart again: the live ray
const RISE_STEP := 0.003                   # a strength change smaller than this between frames is noise, not the fingers closing
const JOINT_ON := 0.022                    # without the interaction profile the strength comes from the thumb-index tip distance:
const JOINT_FAR := 0.065                   # 1 at JOINT_ON, 0 at JOINT_FAR
const LOST_GRACE := 0.15                   # a hand missing for less than this is bridged
const PINCH_HISTORY_S := 0.6               # how far back the ray is searched for where the fingers began to close
const PALM_UP_Y := 0.6                     # the palm normal's Y above which the palm faces up
const AIM_DOT_PROFILE := 0.0               # the ray must point this far forward (dot with the head's forward) to count as aiming...
const AIM_DOT_JOINT := 0.1                 # ...and this far for the finger-joint fallback ray

# ------------------------------------------------------------------------------------------------ stylus (StylusInput, PenController)
const TIP_ON := 0.035
const TIP_OFF := 0.018
const MID_ON := 0.09
const MID_OFF := 0.05
const NIB_SAMPLES := 45                    # frames over which the nib is averaged in the grip pose's frame to align the stylus model
const PRESSURE_EXP := 0.75
const STYLUS_FILTER := Vector2(2.2, 45.0)  # One-Euro (min cutoff, beta) of the nib

# ------------------------------------------------------------------------------------------------ the menu (XrRig, XrPanel)
const POKE_PRESS := 0.015                  # a fingertip or nib this close in front of the menu presses...
const POKE_RELEASE := 0.03                 # ...and lets go this far out
const POKE_BEHIND := 0.05                  # the touch zone reaches this far behind the menu...
const POKE_FRONT := 0.08                   # ...and this far in front of it
const POKE_MARGIN := 0.01                  # outside the panel's edge by this much still counts
const MENU_RAY_REACH := 1.4                # a pointing ray reaches the menu from this far
const HANDLE_Y := 0.03                     # the move handle hangs this far under the menu
const HANDLE_NEAR := 0.07                  # a pinch point or nib this close to the handle can grab it...
const HANDLE_RAY_R := 0.06                 # ...and a pointing ray this close to it
const MENU_MAX_DIST := 2.5                 # a menu further away than this comes back
const SCROLL_DEADZONE := 14.0              # px a press must move on a scrolling list before it is a drag (horizontal: x SCROLL_SIDE)
const SCROLL_SIDE := 1.6
const GLOVES_OFF_NEAR := 0.2               # the gloves hide while the stylus nib is this close to a canvas

# ------------------------------------------------------------------------------------------------ bringing the menu
const SUMMON_HOLD_S := 0.6                 # palm up, or the stylus front button held away from a canvas, this long
const PALM_SUMMON_DIST := 0.7              # the palm must be this close to the head
const PALM_REARM_S := 2.0                  # after a summon the gesture re-arms once the palm was away this long
const SUMMON_AHEAD := 0.55                 # where the dock comes to (the middle of its lower edge): this far ahead of the head, ...
const SUMMON_RIGHT := 0.0                  # ...this far to the right (negative: left), ...
const SUMMON_UP := -0.3                    # ...and this far up (negative: down): low, like a keyboard, out of the way of the view
const SUMMON_STYLUS_CANVAS := 0.14         # the front button summons only with the nib further than this from every canvas

# ------------------------------------------------------------------------------------------------ the board: pen
const CAPTURE := 0.12                      # a nib this close (m) to a canvas draws on it
const SLACK := 0.6                         # ...and inside its extent grown by this
const HOVER_RANGE := 0.28
const MIN_STEP := 0.0009                   # metres between stroke samples
const HOLD_MOVE := 0.004                   # the pen counts as still while it stays within this
const UNSNAP_MOVE := 0.012                 # moving this far (x2) from where a stroke snapped un-snaps it
const ERASE_R := 0.014
const PICK_R := 0.013
const HANDLE_HIT := 0.034
const BTN_HIT := 0.028
const LASSO_INSIDE := 0.6                  # a loop selects an item when this share of it is inside
const SHAPE_TAP := 0.025                   # a shape dragged less than this is placed at its default size
const MIN_LINE := 0.02                     # a line shorter than this is dropped
const BACK_HAPTIC := Vector2(0.4, 0.02)

# ------------------------------------------------------------------------------------------------ the board: grabbing canvases
## One vocabulary for the hands (pinch) and the stylus (front button): a pointer within DIRECT_NEAR of a canvas touches it, further away
## the ray chooses what is grabbed and the pinch point's movement carries it.
const DIRECT_NEAR := 0.12                  # the pinch point or nib this close to a canvas plane: direct
const DIRECT_STAY := 1.3                   # ...and it stays direct until it is this many times further
const DIRECT_REACH := 1.6                  # item pick radii when touching (a finger is not as fine as a nib)
const REACH := 2.6                         # item pick radii at a distance: a ray at arm's length is not a nib
const BAR_DROP := 0.07                     # the bar sits this far below the canvas's bottom edge
const BAR_HIT_W := 0.20                    # half width / half height of the area that counts as the bar
const BAR_HIT_H := 0.07
const CORNER_HIT := 0.075
const PLANE_SLACK := 0.2                   # a pointer may meet a canvas this far outside its extent
const MOVE_START := 0.02                   # a pinch on empty canvas that moves this far carries the canvas; less is a tap
const MAX_GAIN := 6.0                      # the most a far canvas (or menu) moves per metre of hand movement
const MIN_GAIN_DIST := 0.25
const MIN_CANVAS := Vector2(0.25, 0.18)
const MARKER_SIDE := 0.04                  # the markers of a curved desk stand this far outside the left edge of the shown part...
const MARKER_R := 0.024                    # ...are drawn this big...
const MARKER_HIT := 0.05                  # ...and are taken hold of from this close
const TWO_HAND_MIN := 0.04                 # two hands this close do not turn / scale yet
const TWO_HAND_RATIO := Vector2(0.2, 6.0)
const CANVAS_SCALE := Vector2(0.15, 8.0)

# ------------------------------------------------------------------------------------------------ cursors
const CORNER_R := 0.014
const BAR_LEN := 0.30
const BAR_R := 0.0075
const RING_R := 0.011                      # ring radius at 0.7 m...
const RING_MIN := 0.006                    # ...clamped to this range
const RING_MAX := 0.05
const RAY_W := 0.004                       # the stylus's beam (StylusRay): width, its dark edge included...
const RAY_MIN_PX := 1.5                    # ...never thinner than this on the screen (fainter instead)
const RAY_IDLE_LEN := 0.5                  # pointing at nothing: a beam this long that fades out, like the Quest's own
const RAY_MAX_LEN := 12.0


## How much further a carried thing moves than the hand carrying it: the ratio of its distance from the head to the hand's, 1 to MAX_GAIN.
static func carry_gain(head: Vector3, thing: Vector3, hand: Vector3) -> float:
	return clampf(head.distance_to(thing) / maxf(head.distance_to(hand), MIN_GAIN_DIST), 1.0, MAX_GAIN)
