extends Node2D

## Milestone 1 entry point.
##
## Sets up the single sprite, then "clicks the green flag": it hands the
## hardcoded block script (data) to the interpreter, which drives the sprite
## via GDScript coroutines. There is intentionally no editor and no UI yet.

@onready var sprite: Sprite2D = $Sprite

## Held as a member so the interpreter (a RefCounted) outlives _ready(); its
## running coroutines depend on it staying alive.
var _interpreter: Interpreter


func _ready() -> void:
	sprite.texture = _make_placeholder_texture()
	sprite.position = get_viewport_rect().size * 0.5  # start centered on the stage

	var target := Target.new(sprite)
	_interpreter = Interpreter.new(get_tree(), target)
	_interpreter.run(ExampleScript.build())


## Generate a plain colored square in code so the project has no dependency on
## any imported image asset. (Later milestones can swap in real costumes.)
func _make_placeholder_texture() -> Texture2D:
	var size := 48
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.65, 1.0))  # friendly blue
	return ImageTexture.create_from_image(image)
