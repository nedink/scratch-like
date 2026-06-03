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

## Facing direction in degrees, using Scratch's convention:
##   90 = right (+x), 0 = up (-y on screen), and the angle increases clockwise.
var direction: float = 90.0


func _init(target_node: Node2D) -> void:
	node = target_node
