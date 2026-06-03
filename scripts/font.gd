class_name PixelFont
extends RefCounted

## A bitmap font baked from res://font.png — the Milestone 6 text renderer.
##
## The atlas stacks two faces, each a two-row grid of A-Z then 0-9 (a character's
## column index into its row string is its column in the atlas):
##   * "small" — 3x5 glyphs, 1px spacing, letters at y=0,  digits at y=6
##   * "large" — 5x9 glyphs, 2px spacing, letters at y=16, digits at y=27
## A face's glyphs step every (cell + spacing) px along a row, and each row steps
## one line (cell + spacing) below the last, so the digit row's y follows from the
## letter row's. The "large" face exists so text can be drawn at the viewport's own
## resolution — big enough to read without scaling the sprite up (which the "small"
## face needs to be legible). See the `say` block.
##
## render() composites a string into a fresh RGBA texture at the chosen face's
## *native* pixel size: each white glyph pixel becomes `color`, everything else is
## transparent. That texture is exactly a sprite costume, so the `say` block can
## make any sprite *wear* its text — the "text-rendering costume" the earlier
## milestones kept deferring. Loading the atlas image (and so the glyph lookup) is
## node-agnostic, matching the rest of the runtime: the Stage owns one shared
## PixelFont and the interpreter renders through it.

const _ATLAS_PATH := "res://font.png"
## The two glyph rows in the atlas, and the characters each holds in order.
const _LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const _DIGITS := "0123456789"

## The faces, keyed by the size name the `say` block passes. Each gives the glyph
## cell size (w, h), the inter-glyph/line spacing, and the atlas y of its letter
## row; the digit row sits one line (h + spacing) below.
const _FACES := {
	"small": {"w": 3, "h": 5, "spacing": 1, "letters_y": 0},
	"large": {"w": 5, "h": 9, "spacing": 2, "letters_y": 16},
}
const _DEFAULT_FACE := "small"

## The decoded atlas image, read once. White pixels are glyph ink.
var _atlas: Image


func _init() -> void:
	# load() returns the imported (lossless) texture; get_image() decodes it back
	# to a readable Image so we can sample glyph pixels at runtime.
	var texture := load(_ATLAS_PATH) as Texture2D
	if texture != null:
		_atlas = texture.get_image()
	if _atlas == null:
		push_warning("PixelFont: could not load atlas '%s'" % _ATLAS_PATH)


## Render `text` into an ImageTexture: white glyph pixels recolored to `color` on
## a transparent ground, in the `size` face ("small" / "large"). Honors "\n" and
## uppercases letters; a space or any unsupported character leaves a blank
## glyph-sized gap. The texture is the face's native pixel size — no scaling.
func render(text: String, color: Color = Color.WHITE, size: String = _DEFAULT_FACE) -> ImageTexture:
	var face: Dictionary = _FACES.get(size, _FACES[_DEFAULT_FACE])
	var spacing: int = face["spacing"]
	var advance_x: int = face["w"] + spacing  # step to the next glyph on a line
	var advance_y: int = face["h"] + spacing  # step to the next line

	var lines := text.split("\n")
	var columns := 0
	for line in lines:
		columns = maxi(columns, line.length())

	# A run of N glyphs spans N cells minus the trailing spacing; clamp to >=1 so
	# an empty string still yields a valid 1x1 texture.
	var width := maxi(1, columns * advance_x - spacing)
	var height := maxi(1, lines.size() * advance_y - spacing)
	# Pad to even dimensions (the extra row/column stays transparent). A centered
	# Sprite2D wearing an odd-sized costume sits on a half-pixel boundary
	# (e.g. 36 - 5/2 = 33.5), so the viewport upscale samples the glyphs' 1px edge
	# strokes inconsistently and a digit's flat top/bottom can vanish — "0" reading
	# as two cut-off bars. Even dimensions put the edges on whole pixels at an
	# integer position, so the costume stays crisp at native scale (no node scaling).
	width += width % 2
	height += height % 2
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for row in lines.size():
		var line: String = lines[row]
		for col in line.length():
			_blit_glyph(image, line[col], col * advance_x, row * advance_y, color, face)

	return ImageTexture.create_from_image(image)


## Copy one glyph's ink into `image` at (dest_x, dest_y), painting set pixels
## `color`. A blank glyph (space / unsupported) is a no-op, leaving the gap clear.
func _blit_glyph(image: Image, ch: String, dest_x: int, dest_y: int, color: Color, face: Dictionary) -> void:
	var origin := _glyph_origin(ch, face)
	if origin.x < 0 or _atlas == null:
		return
	for gy in face["h"]:
		for gx in face["w"]:
			if _atlas.get_pixel(origin.x + gx, origin.y + gy).r > 0.5:
				image.set_pixel(dest_x + gx, dest_y + gy, color)


## The atlas pixel origin of `ch`'s glyph in `face`, or Vector2i(-1, -1) for a
## blank (space / unsupported character). Letters are uppercased first.
func _glyph_origin(ch: String, face: Dictionary) -> Vector2i:
	var c := ch.to_upper()
	var advance_x: int = face["w"] + face["spacing"]
	var letters_y: int = face["letters_y"]
	var digits_y: int = letters_y + face["h"] + face["spacing"]
	var i := _LETTERS.find(c)
	if i >= 0:
		return Vector2i(i * advance_x, letters_y)
	i = _DIGITS.find(c)
	if i >= 0:
		return Vector2i(i * advance_x, digits_y)
	return Vector2i(-1, -1)
