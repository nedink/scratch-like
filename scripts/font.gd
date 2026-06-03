class_name PixelFont
extends RefCounted

## A bitmap font baked from res://font.png — the Milestone 6 text renderer.
##
## The atlas is a 3x5-pixel glyph grid: glyphs are GLYPH_W wide and GLYPH_H tall,
## laid out every ADVANCE_X pixels (3 + 1px letter spacing) along a row.
##   * Row 1 (y = 0):           A-Z
##   * Row 2 (y = ADVANCE_Y):   0-9
##
## render() composites a string into a fresh RGBA texture: each white glyph pixel
## becomes `color`, everything else is transparent. That texture is exactly a
## sprite costume, so the `say` block can make any sprite *wear* its text — the
## "text-rendering costume" the earlier milestones kept deferring. Loading the
## atlas image (and so the glyph lookup) is node-agnostic, matching the rest of
## the runtime: the Stage owns one shared PixelFont and the interpreter renders
## through it.

## Glyph cell geometry (pixels). Letter spacing and line spacing are both 1px, so
## the advance from one glyph/line to the next is the cell size plus that gap.
const GLYPH_W := 3
const GLYPH_H := 5
const SPACING := 1
const ADVANCE_X := GLYPH_W + SPACING  # 4: step to the next glyph on a line
const ADVANCE_Y := GLYPH_H + SPACING  # 6: step to the next line

const _ATLAS_PATH := "res://font.png"
## The two glyph rows in the atlas, and the characters each holds in order. A
## character's column index into its row string is also its column in the atlas.
const _LETTERS := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
const _DIGITS := "0123456789"
const _LETTER_ROW_Y := 0
const _DIGIT_ROW_Y := ADVANCE_Y

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
## a transparent ground. Honors "\n" (1px line spacing) and uppercases letters;
## a space or any unsupported character leaves a blank glyph-sized gap.
func render(text: String, color: Color = Color.WHITE) -> ImageTexture:
	var lines := text.split("\n")
	var columns := 0
	for line in lines:
		columns = maxi(columns, line.length())

	# A run of N glyphs spans N cells minus the trailing spacing; clamp to >=1 so
	# an empty string still yields a valid 1x1 texture.
	var width := maxi(1, columns * ADVANCE_X - SPACING)
	var height := maxi(1, lines.size() * ADVANCE_Y - SPACING)
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for row in lines.size():
		var line: String = lines[row]
		for col in line.length():
			_blit_glyph(image, line[col], col * ADVANCE_X, row * ADVANCE_Y, color)

	return ImageTexture.create_from_image(image)


## Copy one glyph's ink into `image` at (dest_x, dest_y), painting set pixels
## `color`. A blank glyph (space / unsupported) is a no-op, leaving the gap clear.
func _blit_glyph(image: Image, ch: String, dest_x: int, dest_y: int, color: Color) -> void:
	var origin := _glyph_origin(ch)
	if origin.x < 0 or _atlas == null:
		return
	for gy in GLYPH_H:
		for gx in GLYPH_W:
			if _atlas.get_pixel(origin.x + gx, origin.y + gy).r > 0.5:
				image.set_pixel(dest_x + gx, dest_y + gy, color)


## The atlas pixel origin of `ch`'s glyph, or Vector2i(-1, -1) for a blank
## (space / unsupported character). Letters are uppercased first.
func _glyph_origin(ch: String) -> Vector2i:
	var c := ch.to_upper()
	var i := _LETTERS.find(c)
	if i >= 0:
		return Vector2i(i * ADVANCE_X, _LETTER_ROW_Y)
	i = _DIGITS.find(c)
	if i >= 0:
		return Vector2i(i * ADVANCE_X, _DIGIT_ROW_Y)
	return Vector2i(-1, -1)
