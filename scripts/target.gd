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

## Per-sprite ("for this sprite only") variables: name (String) -> value.
## Resolved *before* the Stage's globals, so a local shadows a global of the
## same name (Scratch semantics). The ball keeps its `speed` here.
var variables: Dictionary = {}

## True only for runtime clones (set by Stage.create_clone_of). `delete_this_clone`
## refuses to run on an original — matching Scratch, where the block is a no-op
## outside a clone.
var is_clone: bool = false


func _init(target_node: Node2D, target_name: String) -> void:
	node = target_node
	name = target_name
