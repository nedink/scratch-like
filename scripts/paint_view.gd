class_name PaintView
extends Control

## The Milestone 45 **pixel costume editor** — the third editor surface, beside the block canvas
## (a sprite's *script*) and the stage view (a sprite's *geometry*). This edits a sprite's
## *costume*: a grid of pixels that becomes the sprite's texture at RUN, instead of the flat
## placeholder colour every sprite drew through M44.
##
## Like StageView it is a pure editor-side view over the data-owned sprite model (editor._scripts —
## an Array of {name, x, y, w, h, color, script} dicts). M45 adds one optional key, `costume`:
##
##   "costume": {
##       "cw": 16, "ch": 16,                    # resolution in pixels
##       "palette": ["#000000", "#ffffff", ...],# "#rrggbb", opaque
##       "pixels": [-1, -1, 0, 1, ...]          # row-major, length cw*ch; -1 = transparent
##   }
##
## We hold a **reference** to that array (set_model) and mutating the selected entry's
## costume.pixels in place *is* the edit (the M9 data-is-canonical idiom). RUN reads the costume
## (Stage._make_costume_texture) and SAVE serialises it as plain JSON, so costume edits ride those
## paths with no new plumbing — and there is no new opcode and no block-data-shape change.
##
## Rendering is **no-stretch**: a costume draws 1 costume-pixel = 1 model-pixel at RUN (crisp,
## TEXTURE_FILTER_NEAREST), never scaled to fit w/h — so the costume's resolution *is* the sprite's
## footprint. To keep collision (touching_sprite?), the inspector, and the stage preview agreeing
## with what's drawn, creating a costume sets the entry's w/h to cw/ch.
##
## Tools (a click/drag surface, the StageView IDLE->PENDING->DRAGGING input adapted): pencil and
## eraser paint along a drag, fill flood-fills from a click, eyedropper picks a colour, plus a
## palette of swatches, a colour picker to recolour the active swatch, and clear-all. Everything is
## built in code (the dynamic palette favours it), so editor.tscn carries only this one Control.
##
## Deferred (see CLAUDE.md): multiple costumes per sprite / costume-switching blocks, animation
## frames, undo, PNG import, a shared project palette, and a resize-canvas tool (cw/ch are fixed at
## creation — which is why StageView suppresses its resize handle once a costume exists).

## Drag state machine (cf. block_canvas / stage_view).
const _IDLE := 0
const _PENDING := 1
const _DRAGGING := 2

## Default costume resolution for a freshly painted sprite (Scratch-ish small sprite).
const _DEFAULT_CW := 16
const _DEFAULT_CH := 16
## A new costume's resolution is the sprite's current w/h clamped to this range (so a huge sprite
## doesn't make a huge grid, and a 1x1 HUD still has a paintable canvas).
const _MIN_RES := 4
const _MAX_RES := 64

## The target box (display px) the grid is scaled to fit at zoom 1 — the base cell size is derived
## so a small costume fills it with big cells and a large one still fits (_recompute_scale); the
## user's zoom multiplies that base.
const _VIEW_BOX := 384.0

## Zoom multiplies the fit-derived base cell size; the grid lives in a ScrollContainer so a
## zoomed-in costume can be panned to reach its edges. Stepped by _ZOOM_STEP, clamped to the range.
const _ZOOM_MIN := 0.5
const _ZOOM_MAX := 12.0
const _ZOOM_STEP := 1.25

## The stock palette a fresh costume starts with — the 16-colour **PICO-8** palette (the de facto
## standard pixel-art palette), in its canonical index order (0 black … 15 peach), a tidy 4-column
## grid. Opaque "#rrggbb"; transparency is the -1 pixel sentinel.
const _DEFAULT_PALETTE := [
	"#000000", "#1d2b53", "#7e2553", "#008751",
	"#ab5236", "#5f574f", "#c2c3c7", "#fff1e8",
	"#ff004d", "#ffa300", "#ffec27", "#00e436",
	"#29adff", "#83769c", "#ff77a8", "#ffccaa",
]


## The pixel grid draw layer — a custom-_draw child that paints the costume: a checkerboard for
## transparent cells, the palette colour otherwise, with thin grid lines. Pointed at the costume's
## live pixels/palette arrays (so a paint that mutates them just needs queue_redraw). Hit-testing
## reads its global_position, so its container layout doesn't matter (cf. StageView._world).
class _PixelGrid:
	extends Control
	var cw: int = 16
	var ch: int = 16
	var cell_px: float = 16.0  # display px per costume pixel (named to avoid Control's inherited `scale`)
	var pixels: Array = []     # reference to the costume's pixels (or a transient preview)
	var palette: Array = []    # reference to the costume's palette (or a transient preview)
	const _CHECK_A := Color(0.16, 0.16, 0.20)
	const _CHECK_B := Color(0.23, 0.23, 0.29)
	const _LINE := Color(0, 0, 0, 0.25)

	func _draw() -> void:
		for y in ch:
			for x in cw:
				var rect := Rect2(x * cell_px, y * cell_px, cell_px, cell_px)
				var k := y * cw + x
				var idx := -1
				if k < pixels.size():
					idx = int(pixels[k])
				if idx < 0 or idx >= palette.size():
					draw_rect(rect, _CHECK_A if (x + y) % 2 == 0 else _CHECK_B)
				else:
					draw_rect(rect, Color(String(palette[idx])))
		# Cell grid lines, but only when cells are big enough that lines read as a guide rather than noise.
		if cell_px >= 6.0:
			for x in cw + 1:
				draw_line(Vector2(x * cell_px, 0), Vector2(x * cell_px, ch * cell_px), _LINE, 1.0)
			for y in ch + 1:
				draw_line(Vector2(0, y * cell_px), Vector2(cw * cell_px, y * cell_px), _LINE, 1.0)


## The sprite model being edited — a reference to editor._scripts (the same dicts RUN/SAVE read).
var _sprites: Array = []
var _selected: int = -1

## Editor callback (mirrors stage_view.on_geometry_changed): a paint changed the selected sprite's
## costume (and possibly its w/h, when the costume was just created), so the editor re-syncs.
var on_costume_changed: Callable

## What the grid currently shows. When the selected sprite has a costume these reference its live
## arrays (mutating them *is* the edit); with no costume yet they're a transient all-transparent
## preview that the first paint replaces via _ensure_costume.
var _display_cw: int = _DEFAULT_CW
var _display_ch: int = _DEFAULT_CH
var _display_palette: Array = []
var _display_pixels: Array = []

## The active paint colour (palette index) and current tool.
var _active_index: int = 0
var _tool: String = "pencil"

## Set while we push values into the colour picker, so its color_changed signal doesn't echo back.
var _loading: bool = false

# Built-in-code chrome.
var _grid: _PixelGrid
var _grid_scroll: ScrollContainer
var _swatch_grid: GridContainer
var _color_picker: ColorPickerButton
var _tool_group: ButtonGroup
var _zoom_label: Label

## User zoom multiplier on top of the fit-derived base cell size (see _recompute_scale). Persists
## across selection / costume changes so the chosen zoom sticks while you work.
var _zoom: float = 1.0

# Drag state.
var _state: int = _IDLE
var _press_pos: Vector2
var _last_cell: Vector2i = Vector2i(-1, -1)


func _ready() -> void:
	# PASS (not STOP): the wheel still reaches any enclosing container, and we drive painting from
	# _input with our own global hit-testing — a press off the grid falls through to the chrome buttons.
	mouse_filter = Control.MOUSE_FILTER_PASS
	_display_palette = _DEFAULT_PALETTE.duplicate()
	_display_pixels = _make_empty(_DEFAULT_CW, _DEFAULT_CH)
	_build_chrome()


## Build the surface: [ centred pixel grid | a tools panel ]. The tools panel is created in code
## because the palette swatches are dynamic (one per costume colour).
func _build_chrome() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	# Left: the grid in a ScrollContainer, so zooming in past the viewport lets you pan to reach the
	# costume's edges. The grid is shrink-centred, so when it's smaller than the viewport it sits
	# centred (no scrollbars), and only scrolls once a zoom makes it overflow.
	_grid_scroll = ScrollContainer.new()
	_grid_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_grid_scroll)

	_grid = _PixelGrid.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE  # we hit-test it manually from _input
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_grid_scroll.add_child(_grid)

	# Right: the tools panel.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(180, 0)
	root.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	var tools_label := Label.new()
	tools_label.text = "Tools"
	col.add_child(tools_label)

	# Tool buttons in a toggle group, so exactly one is active and it reads as pressed.
	_tool_group = ButtonGroup.new()
	var tools_grid := GridContainer.new()
	tools_grid.columns = 2
	col.add_child(tools_grid)
	for spec in [["pencil", "Pencil"], ["eraser", "Eraser"], ["fill", "Fill"], ["eyedropper", "Eyedropper"]]:
		var b := Button.new()
		b.text = String(spec[1])
		b.toggle_mode = true
		b.button_group = _tool_group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.set_meta("tool", String(spec[0]))
		if String(spec[0]) == _tool:
			b.button_pressed = true
		b.pressed.connect(_on_tool.bind(String(spec[0])))
		tools_grid.add_child(b)

	col.add_child(HSeparator.new())

	var colors_label := Label.new()
	colors_label.text = "Colours"
	col.add_child(colors_label)

	_swatch_grid = GridContainer.new()
	_swatch_grid.columns = 4
	col.add_child(_swatch_grid)

	_color_picker = ColorPickerButton.new()
	_color_picker.custom_minimum_size = Vector2(0, 28)
	_color_picker.text = "Edit colour"
	_color_picker.edit_alpha = false  # palette colours are opaque; transparency is the eraser/-1
	_color_picker.color_changed.connect(_on_color_changed)
	col.add_child(_color_picker)

	col.add_child(HSeparator.new())

	# Zoom: − [percent] + , plus Ctrl+wheel over the grid (see _input).
	var zoom_label := Label.new()
	zoom_label.text = "Zoom"
	col.add_child(zoom_label)

	var zoom_row := HBoxContainer.new()
	zoom_row.add_theme_constant_override("separation", 4)
	col.add_child(zoom_row)
	var zoom_out := Button.new()
	zoom_out.text = "−"
	zoom_out.custom_minimum_size = Vector2(32, 0)
	zoom_out.pressed.connect(_on_zoom.bind(1.0 / _ZOOM_STEP))
	zoom_row.add_child(zoom_out)
	_zoom_label = Label.new()
	_zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zoom_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zoom_row.add_child(_zoom_label)
	var zoom_in := Button.new()
	zoom_in.text = "+"
	zoom_in.custom_minimum_size = Vector2(32, 0)
	zoom_in.pressed.connect(_on_zoom.bind(_ZOOM_STEP))
	zoom_row.add_child(zoom_in)

	col.add_child(HSeparator.new())

	var clear_button := Button.new()
	clear_button.text = "Clear all"
	clear_button.pressed.connect(_on_clear)
	col.add_child(clear_button)

	_rebuild_swatches()
	_update_picker_from_active()
	_update_zoom_label()


# --- Editor entry points (mirroring StageView.set_model / set_selected / refresh) -------------

## Point at a model array and select an index (entering Paint mode, or after NEW/OPEN replaces the
## working project so the old reference is stale). Re-syncs the grid + swatches to the selection.
func set_model(sprites: Array, selected: int) -> void:
	_sprites = sprites
	_selected = selected
	_sync_from_model()


## Change only the selection (the sprite selector changed while in Paint mode). The model reference
## is unchanged, but the costume — and its palette — differ per sprite, so re-sync the whole grid.
func set_selected(index: int) -> void:
	_selected = index
	_sync_from_model()


## Point the grid + swatches at the selected sprite's costume (its live arrays), or at a transient
## all-transparent preview when it has none yet (the first paint creates the real costume).
func _sync_from_model() -> void:
	var entry := _selected_entry()
	if not entry.is_empty() and _valid_costume(entry.get("costume", {})):
		var c: Dictionary = entry["costume"]
		_display_cw = int(c["cw"])
		_display_ch = int(c["ch"])
		_display_palette = c["palette"]   # reference — editing a swatch edits the costume
		_display_pixels = c["pixels"]     # reference — painting mutates the model
	else:
		# A transient all-transparent preview at the resolution the first paint will create (the
		# sprite's clamped w/h), so the grid doesn't jump size when painting begins.
		var res := _new_res(entry)
		_display_cw = res.x
		_display_ch = res.y
		_display_palette = _DEFAULT_PALETTE.duplicate()
		_display_pixels = _make_empty(res.x, res.y)
	if _active_index >= _display_palette.size():
		_active_index = 0
	_recompute_scale()
	_push_grid()
	_update_zoom_label()
	_rebuild_swatches()
	_update_picker_from_active()


# --- Painting --------------------------------------------------------------

## Drive painting from _input (before GUI input) with our own global hit-testing, mirroring
## stage_view. A press on the grid paints immediately (a click sets one pixel); a press off the grid
## falls through untouched so the tool/swatch buttons beside us still work.
func _input(event: InputEvent) -> void:
	# Shares the OS window with the other editor surfaces and still receives _input while hidden
	# (the mode toggle); ignore events unless we're the visible surface.
	if not is_visible_in_tree():
		return

	# Ctrl+wheel anywhere over the grid's viewport zooms (a plain wheel falls through to scroll the
	# ScrollContainer). We test the whole scroll rect, not just a grid cell, so wheeling over the
	# blank margin around a shrink-centred costume still zooms instead of silently doing nothing.
	if event is InputEventMouseButton and event.ctrl_pressed \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
			and event.pressed and _grid_scroll != null \
			and _grid_scroll.get_global_rect().has_point(event.position):
		_on_zoom(_ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / _ZOOM_STEP)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			var cell := _cell_at(event.position)
			if cell.x < 0:
				return  # missed the grid — let the chrome buttons handle the click
			_state = _PENDING
			_press_pos = event.position
			_last_cell = cell
			_apply_tool(cell)
			get_viewport().set_input_as_handled()
		elif not event.pressed:
			_state = _IDLE
			_last_cell = Vector2i(-1, -1)
	elif event is InputEventMouseMotion and (_state == _PENDING or _state == _DRAGGING):
		_state = _DRAGGING
		# Only the freehand tools paint along a drag; fill / eyedropper act once, on the press.
		if _tool == "pencil" or _tool == "eraser":
			var cell := _cell_at(event.position)
			if cell.x >= 0 and cell != _last_cell:
				_paint_line(_last_cell, cell)
				_last_cell = cell
		get_viewport().set_input_as_handled()


## Which costume cell is under a global point, or (-1, -1) if off the grid. The inverse of the grid's
## cell layout — subtract the grid's global origin, divide out the display scale, bounds-check.
func _cell_at(global_point: Vector2) -> Vector2i:
	if _grid == null:
		return Vector2i(-1, -1)
	var local := global_point - _grid.global_position
	if local.x < 0.0 or local.y < 0.0:
		return Vector2i(-1, -1)
	var cx := int(local.x / _grid.cell_px)
	var cy := int(local.y / _grid.cell_px)
	if cx >= _display_cw or cy >= _display_ch:
		return Vector2i(-1, -1)
	return Vector2i(cx, cy)


## Apply the current tool at a cell. Pencil/eraser/fill mutate (creating the costume on first paint);
## eyedropper reads. All notify the editor once at the end (so it can re-sync after a w/h change).
func _apply_tool(cell: Vector2i) -> void:
	match _tool:
		"eyedropper":
			var k := cell.y * _display_cw + cell.x
			if k >= 0 and k < _display_pixels.size():
				var idx := int(_display_pixels[k])
				if idx >= 0 and idx < _display_palette.size():
					_active_index = idx
					_select_tool("pencil")  # picking a colour implies you want to draw with it
					_update_picker_from_active()
					_highlight_swatches()
		"fill":
			_ensure_costume()
			_flood_fill(cell, _active_index)
			_after_paint()
		_:  # pencil / eraser
			_ensure_costume()
			_plot(cell, -1 if _tool == "eraser" else _active_index)
			_after_paint()


## Paint a straight line of cells between two grid cells (Bresenham), so a fast drag leaves no gaps.
func _paint_line(from: Vector2i, to: Vector2i) -> void:
	_ensure_costume()
	var idx := -1 if _tool == "eraser" else _active_index
	var x0 := from.x
	var y0 := from.y
	var dx := absi(to.x - x0)
	var dy := -absi(to.y - y0)
	var sx := 1 if x0 < to.x else -1
	var sy := 1 if y0 < to.y else -1
	var err := dx + dy
	while true:
		_plot(Vector2i(x0, y0), idx)
		if x0 == to.x and y0 == to.y:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	_after_paint()


## Write one cell's palette index (no redraw/notify — the callers batch that via _after_paint).
func _plot(cell: Vector2i, idx: int) -> void:
	if cell.x < 0 or cell.y < 0 or cell.x >= _display_cw or cell.y >= _display_ch:
		return
	_display_pixels[cell.y * _display_cw + cell.x] = idx


## Flood-fill from a cell: replace the contiguous region of the cell's current index with `idx`
## (4-connected). Bounded by the grid, so it always terminates.
func _flood_fill(cell: Vector2i, idx: int) -> void:
	if cell.x < 0 or cell.y >= _display_ch:
		return
	var target := int(_display_pixels[cell.y * _display_cw + cell.x])
	if target == idx:
		return
	var queue: Array[Vector2i] = [cell]
	while not queue.is_empty():
		var c: Vector2i = queue.pop_back()
		if c.x < 0 or c.y < 0 or c.x >= _display_cw or c.y >= _display_ch:
			continue
		var k := c.y * _display_cw + c.x
		if int(_display_pixels[k]) != target:
			continue
		_display_pixels[k] = idx
		queue.push_back(Vector2i(c.x + 1, c.y))
		queue.push_back(Vector2i(c.x - 1, c.y))
		queue.push_back(Vector2i(c.x, c.y + 1))
		queue.push_back(Vector2i(c.x, c.y - 1))


## Redraw the grid and tell the editor a costume changed (so it re-syncs the inspector / a w/h shift).
func _after_paint() -> void:
	if _grid:
		_grid.queue_redraw()
	if on_costume_changed.is_valid():
		on_costume_changed.call(_selected)


## Create a costume on the selected sprite if it has none, then point the display arrays at it. The
## new costume's resolution is the sprite's current w/h clamped to [_MIN_RES, _MAX_RES]; we set the
## entry's w/h to that so the no-stretch render footprint, collision, and inspector all agree.
func _ensure_costume() -> void:
	var entry := _selected_entry()
	if entry.is_empty():
		return
	if _valid_costume(entry.get("costume", {})):
		var existing: Dictionary = entry["costume"]
		_display_pixels = existing["pixels"]
		_display_palette = existing["palette"]
		return
	var res := _new_res(entry)
	var cw := res.x
	var ch := res.y
	var costume := {
		"cw": cw,
		"ch": ch,
		"palette": _display_palette.duplicate(),  # carry any pre-creation swatch edits
		"pixels": _make_empty(cw, ch),
	}
	entry["costume"] = costume
	entry["w"] = cw
	entry["h"] = ch
	_display_cw = cw
	_display_ch = ch
	_display_palette = costume["palette"]
	_display_pixels = costume["pixels"]
	_recompute_scale()
	_push_grid()
	_update_zoom_label()
	_rebuild_swatches()


# --- Tool / colour UI ------------------------------------------------------

func _on_tool(tool_name: String) -> void:
	_tool = tool_name


## Programmatically select a tool (e.g. eyedropper switches to pencil), keeping the toggle group in step.
func _select_tool(tool_name: String) -> void:
	_tool = tool_name
	for b in _tool_group.get_buttons():
		if String(b.get_meta("tool", "")) == tool_name:
			b.button_pressed = true


## The colour picker recolours the **active swatch** (palette entry). Since pixels reference the
## index, every painted pixel using it updates live. Skipped while we set the picker programmatically.
func _on_color_changed(color: Color) -> void:
	if _loading or _active_index < 0 or _active_index >= _display_palette.size():
		return
	_display_palette[_active_index] = "#" + color.to_html(false)
	if _grid:
		_grid.queue_redraw()
	_highlight_swatches()
	if _valid_costume(_selected_entry().get("costume", {})) and on_costume_changed.is_valid():
		on_costume_changed.call(_selected)


func _on_clear() -> void:
	# Clearing a sprite with no costume yet is a no-op (nothing painted), so we don't force one.
	if not _valid_costume(_selected_entry().get("costume", {})):
		return
	for i in _display_pixels.size():
		_display_pixels[i] = -1
	_after_paint()


func _on_swatch(index: int) -> void:
	_active_index = index
	_select_tool("pencil")  # picking a colour implies drawing with it
	_update_picker_from_active()
	_highlight_swatches()


## Rebuild the palette swatch buttons (one per colour) — called when the displayed palette changes
## (selection / costume create). Recolouring a single swatch updates in place via _highlight_swatches.
func _rebuild_swatches() -> void:
	if _swatch_grid == null:
		return
	for child in _swatch_grid.get_children():
		# remove_child immediately (queue_free alone is deferred, so the old buttons would still be
		# children when _highlight_swatches runs below — it would colour those, freed next frame, and
		# leave the freshly-added ones grey until the next rebuild).
		_swatch_grid.remove_child(child)
		child.queue_free()
	for i in _display_palette.size():
		var b := Button.new()
		b.custom_minimum_size = Vector2(28, 28)
		b.pressed.connect(_on_swatch.bind(i))
		_swatch_grid.add_child(b)
	_highlight_swatches()


## Colour each swatch button to its palette entry and outline the active one.
func _highlight_swatches() -> void:
	if _swatch_grid == null:
		return
	var kids := _swatch_grid.get_children()
	for i in kids.size():
		if i >= _display_palette.size():
			break
		var b := kids[i] as Button
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(String(_display_palette[i]))
		if i == _active_index:
			sb.border_color = Color("#ffd24d")  # the editor's selection yellow
			sb.set_border_width_all(3)
		else:
			sb.border_color = Color(1, 1, 1, 0.25)
			sb.set_border_width_all(1)
		for sname in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(sname, sb)


func _update_picker_from_active() -> void:
	if _color_picker == null or _active_index < 0 or _active_index >= _display_palette.size():
		return
	_loading = true
	_color_picker.color = Color(String(_display_palette[_active_index]))
	_loading = false


# --- Helpers ---------------------------------------------------------------

func _selected_entry() -> Dictionary:
	if _selected < 0 or _selected >= _sprites.size():
		return {}
	return _sprites[_selected]


## The costume resolution to use for a sprite with no costume yet — its current w/h clamped to the
## paintable range (so a huge sprite doesn't make a huge grid, a 1x1 HUD still has room). Shared by
## the empty-state preview and _ensure_costume, so the preview matches what the first paint creates.
func _new_res(entry: Dictionary) -> Vector2i:
	if entry.is_empty():
		return Vector2i(_DEFAULT_CW, _DEFAULT_CH)
	return Vector2i(
		clampi(int(entry.get("w", _DEFAULT_CW)), _MIN_RES, _MAX_RES),
		clampi(int(entry.get("h", _DEFAULT_CH)), _MIN_RES, _MAX_RES))


## Push the current display resolution/scale/arrays onto the grid draw layer and size it.
func _push_grid() -> void:
	if _grid == null:
		return
	_grid.cw = _display_cw
	_grid.ch = _display_ch
	_grid.cell_px = _scale
	_grid.pixels = _display_pixels
	_grid.palette = _display_palette
	_grid.custom_minimum_size = Vector2(_display_cw * _scale, _display_ch * _scale)
	_grid.queue_redraw()


var _scale: float = 16.0

## Derive the display cell size: a fit-to-_VIEW_BOX base (whole pixels, >= 1px) times the user zoom.
func _recompute_scale() -> void:
	var longest := maxi(_display_cw, _display_ch)
	var base := maxf(1.0, floor(_VIEW_BOX / float(maxi(1, longest))))
	_scale = maxf(1.0, floor(base * _zoom))


## Step the zoom by a factor (the − / + buttons and Ctrl+wheel), clamped, then re-scale the grid.
func _on_zoom(factor: float) -> void:
	_zoom = clampf(_zoom * factor, _ZOOM_MIN, _ZOOM_MAX)
	_recompute_scale()
	_push_grid()
	_update_zoom_label()


## Show the current zoom as the effective cell size (display px per costume pixel) — concrete and
## avoids needing percent glyphs the editor font lacks (this is GUI-font text, so % is fine anyway).
func _update_zoom_label() -> void:
	if _zoom_label:
		_zoom_label.text = str(int(_scale)) + "px"


static func _make_empty(cw: int, ch: int) -> Array:
	var a: Array = []
	a.resize(cw * ch)
	a.fill(-1)
	return a


## A costume dict is usable when it has a positive resolution and array palette + pixels (so a
## malformed / pre-M45 entry falls back to the transient preview rather than erroring).
static func _valid_costume(c: Variant) -> bool:
	if not (c is Dictionary):
		return false
	return int(c.get("cw", 0)) > 0 and int(c.get("ch", 0)) > 0 \
		and (c.get("palette") is Array) and (c.get("pixels") is Array)
