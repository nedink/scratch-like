class_name Target
extends RefCounted

## A "Target" is the thing a block script controls — Scratch calls it a sprite.
##
## It wraps the actual scene node and holds script-level state that lives
## alongside that node (right now just the facing direction). Keeping this in a
## tiny object — instead of on the node itself — means the interpreter never has
## to care what kind of node it is driving, which makes multiple sprites and a
## real editor easy to add later.

## The scene node this target moves around the stage.
var node: Node2D

## The name this target is registered under on the Stage. This is how one
## script refers to *another* entity — e.g. `touching_sprite?("LeftPaddle")`
## resolves through the Stage's registry, which keys on exactly this name.
var name: String

## Facing direction in degrees, using Scratch's convention:
##   90 = right (+x), 0 = up (-y on screen), and the angle increases clockwise.
var direction: float = 90.0

## Built-in velocity (M43), in pixels per *physics tick* (the same fixed-rate unit move_steps
## uses, so a velocity of 6 covers the same ground per tick as `move 6` in a forever). The Stage
## applies it automatically once per physics frame — `node.position += velocity` — so a sprite with
## a non-zero velocity drifts on its own, "behind the scenes", without a per-frame block. Defaults to
## zero, so every existing script (which never touches it) is unaffected. The `set velocity` /
## `change velocity` blocks write it and the `velocity x` / `velocity y` reporters read it; clones
## inherit it from their source (like direction / locals).
var velocity: Vector2 = Vector2.ZERO

## Per-sprite ("for this sprite only") variables: name (String) -> value.
## Resolved *before* the Stage's globals, so a local shadows a global of the
## same name (Scratch semantics). The ball keeps its `speed` here.
var variables: Dictionary = {}

## Per-sprite ("for this sprite only") lists (M44): name (String) -> Array of items. The list
## counterpart of `variables`, resolved the same local-first-then-global way (a local list shadows
## a global of the same name). The list blocks mutate the resolved Array **in place** (add / delete /
## insert / replace), so this dict holds the live containers. A clone inherits a deep copy of its
## source's lists (like locals), so a clone's list edits don't bleed back into the source.
var lists: Dictionary = {}

## True only for runtime clones (set by Stage.create_clone_of). `delete_this_clone`
## refuses to run on an original — matching Scratch, where the block is a no-op
## outside a clone.
var is_clone: bool = false


func _init(target_node: Node2D, target_name: String) -> void:
	node = target_node
	name = target_name
