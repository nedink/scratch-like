class_name BlockStyles
extends Resource

## The per-category block colours, pulled out of block_view.gd so they can be edited
## visually in the Godot inspector (blocks/block_styles.tres) instead of hand-coding hex
## strings. This is the one piece of block *styling* that stays data-applied rather than
## living in a scene: a block's colour is keyed by its **category** (data), so block_view
## tints each instantiated scene's stylebox with `color_for(category)` at build time.
##
## Everything else about a block's look — corner radii, padding, borders, fonts, layout —
## lives in the block scenes (blocks/*.tscn), which you restyle directly in the editor.
##
## Each category is one exported Color so it shows as a friendly colour swatch in the
## inspector. `color_for` looks the property up by the category name; an unknown category
## (or a name with no matching export) falls back to `unknown`.

@export var events := Color("#ffbf00")
@export var control := Color("#ffab19")
@export var motion := Color("#4c97ff")
@export var looks := Color("#9966ff")
@export var sensing := Color("#5cb1d6")
@export var variables := Color("#ff731a")
@export var lists := Color("#cc5b22")
@export var operators := Color("#59c059")
@export var custom := Color("#ff6680")
@export var camera := Color("#0fbd8c")
@export var animation := Color("#cf63cf")
@export var unknown := Color("#7f7f7f")


## The colour for a category, by name (e.g. "motion" -> the blue above). Falls back to
## `unknown` (grey) when the category isn't one of the exported names.
func color_for(category: String) -> Color:
	var c: Variant = get(category)
	return c if c is Color else unknown
