class_name StageView
extends Control

## The Milestone 27 **stage (scene) editor** — the scene counterpart of the block canvas.
## Where block_canvas.gd edits a sprite's *script*, this edits a sprite's *geometry*: it draws
## each sprite's placeholder rectangle at its model position/size/colour and lets you select,
## drag, resize, and recolour it directly on a 480x352 stage.
##
## It is a pure editor-side view over the existing data model. The sprite set has been data-owned
## since M24 — editor._scripts is an Array of {name, x, y, w, h, color, script} dicts — and the
## runtime already builds each sprite at its model x/y with its model w/h/color (Stage._add_sprite).
## So this view holds a **reference to that same array** and a drag simply mutates an entry's
## x/y/w/h in place (the M9 data-is-canonical idiom: the write *is* the edit). RUN reads those
## fields and SAVE serialises them, so geometry edits ride those paths with no new plumbing — and
## there is no new opcode, no block-data-shape change, and no runtime-logic change.
##
## Interaction mirrors block_canvas verbatim: we drive from _input with manual global-coordinate
## hit-testing (the M26 viewport-stretch transform these were written against), an
## IDLE -> PENDING -> DRAGGING state machine with a 4px threshold to split a click (select) from a
## drag (move/resize), and a clear-and-rebuild _render() from the data. Selection is routed back to
## the editor (on_pick) so it flows through the same selector/_show path the dropdown uses; geometry
## changes during a drag call back (on_geometry_changed) so the editor's inspector tracks live.
##
## What it deliberately leaves out (deferred): a live embedded *run* of the game (that needs the
## runtime in a SubViewport, a larger restructure), and uniform / aspect-locked / edge-anchored
## resize (we resize about the centre with independent w/h — the simplest predictable behaviour).

## Pixels the cursor must travel after pressing before a click becomes a drag, so a plain click
## selects a sprite rather than nudging it. Matches block_canvas / block_palette.
const DRAG_THRESHOLD := 4.0

## The runtime's fixed logical stage (matches Stage._GAME_SIZE). Sprite coordinates are authored
## against this, so the editor draws the same space.
const _STAGE_SIZE := Vector2(480, 352)

## The one zoom knob: display pixels per stage logical pixel. The bordered stage region is
## _STAGE_SIZE * _DISPLAY_SCALE; bump it for a bigger stage (less room for the inspector beside it),
## shrink it for the reverse. The editor lays out at 960x540 logical (M26), so 1.25 -> a 600x450
## stage that leaves room for the inspector.
const _DISPLAY_SCALE := 1.25

## Side length (display px) of a corner resize handle on the selected sprite.
const _HANDLE := 10.0

## Smallest sprite dimension a resize can produce (model px), so a sprite can't be shrunk to nothing.
const _MIN_DIM := 4

## Grid spacing in **model** pixels (M27). Drawn lines (and snapping) step by this much; one knob.
## 16 is a useful coarse grid you can actually see at _DISPLAY_SCALE and snap meaningfully to (the
## model is already integer-valued, so a finer step would snap to nothing the round-to-int doesn't).
const _GRID_STEP := 16

## The starting grid colour — a soft sky blue at low alpha, so the overlay reads as a faint guide
## over the dark stage rather than a wash. The user can recolour it from the inspector.
const _DEFAULT_GRID_COLOR := Color(0.529, 0.808, 0.980, 0.35)

## The starting stage background — the dark backdrop the editor has always drawn (kept here so the
## look is unchanged until the user recolours it; the editor seeds the real value from the project).
const _DEFAULT_BACKGROUND := Color("#0c0c12")


## A thin custom-draw layer that paints the alignment grid behind the sprites, clipped to the stage
## region (it is a child of _stage_area, whose clip_contents trims any overshoot). Kept dead simple:
## vertical + horizontal lines every `step` display px in `color`, only when `show` is set. The
## editor toggles `show` and recolours via StageView's set_grid_* setters, which queue_redraw here.
class _GridLayer:
	extends Control
	# Default mirrors StageView._DEFAULT_GRID_COLOR (a bare literal — an inner class can't reference the
	# outer class's constants by name). StageView/the editor overwrites this via set_grid_color anyway.
	var color: Color = Color(0.529, 0.808, 0.980, 0.35)
	var step: float = 1.0   # display px between lines (model _GRID_STEP * _DISPLAY_SCALE); set by StageView
	var show_grid: bool = true

	func _draw() -> void:
		if not show_grid or step <= 0.0:
			return
		var x := step  # skip 0 (it sits under the stage border)
		while x < size.x:
			draw_line(Vector2(x, 0.0), Vector2(x, size.y), color, 1.0)
			x += step
		var y := step
		while y < size.y:
			draw_line(Vector2(0.0, y), Vector2(size.x, y), color, 1.0)
			y += step

# Drag state machine (cf. block_canvas).
const _IDLE := 0
const _PENDING := 1  # pressed on a sprite/handle, not yet moved past the threshold
const _DRAGGING := 2

## The sprite model being edited — a **reference** to editor._scripts (the same dicts RUN/SAVE read).
## Mutating _sprites[i]["x"] etc. is the edit. Set via set_model; never reassigned here.
var _sprites: Array = []

## The selected sprite's index (kept in step with editor._current). -1 when nothing is selected.
var _selected: int = -1

## Editor callbacks (mirroring how block_canvas._trash / block_palette._canvas are injected). Left
## as invalid Callables for any non-editor caller, in which case selection / live-sync are no-ops.
##   on_pick(index)             — a sprite was clicked; the editor selects it (selector + _show).
##   on_geometry_changed(index) — a drag changed an entry's geometry; the editor refreshes the inspector.
var on_pick: Callable
var on_geometry_changed: Callable

## The bordered 480x352 region, centred in this control and clipping its contents so off-stage
## sprites (e.g. the Announcer parked at -400,-400) don't bleed over the inspector. Built in _ready.
var _stage_area: Panel

## Holds the per-sprite rectangles and the selection overlay (outline + handles), all rebuilt in
## _render and hit-tested by get_global_rect — exactly like block_canvas._layer.
var _layer: Control

## The stage region's stylebox, kept so set_background can recolour it live (M27).
var _stage_box: StyleBoxFlat

## The grid overlay layer (M27), drawn behind the sprites; the editor toggles/recolours it via the
## set_grid_* setters.
var _grid: _GridLayer

## Whether a drag snaps the changed value to the grid (M27). On by default; the editor's "Snap to
## grid" checkbox flips it. Applied only when the user actually drags — flipping it never re-snaps
## the existing sprites (per the M27 brief: "only when the user goes to make a change").
var _grid_snap: bool = true

var _state: int = _IDLE
var _press_pos: Vector2            # global position of the initial press
var _pending: Dictionary = {}      # {index, mode, corner?} of the sprite/handle pressed
var _drag_mode: String = ""        # "move" or "resize"
var _drag_index: int = -1          # the sprite being dragged
var _grab_offset_model: Vector2    # (move) sprite centre minus the press point, in model space


func _ready() -> void:
	clip_contents = true
	# PASS (not STOP) so the wheel still reaches any enclosing container; we drive from _input and
	# do our own global hit-testing, same as block_canvas / block_palette.
	mouse_filter = Control.MOUSE_FILTER_PASS

	# The stage region: a dark panel with a light border, clipping its sprite children.
	_stage_area = Panel.new()
	_stage_area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_area.clip_contents = true
	_stage_area.custom_minimum_size = _STAGE_SIZE * _DISPLAY_SCALE
	_stage_area.size = _STAGE_SIZE * _DISPLAY_SCALE
	_stage_box = StyleBoxFlat.new()
	_stage_box.bg_color = _DEFAULT_BACKGROUND
	_stage_box.border_color = Color("#43435a")
	_stage_box.set_border_width_all(1)
	_stage_area.add_theme_stylebox_override("panel", _stage_box)
	add_child(_stage_area)

	# The grid sits behind the sprites: added before _layer so it draws first (lowest), and fills the
	# stage region. Its step is the model grid spacing scaled into display px.
	_grid = _GridLayer.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grid.step = _GRID_STEP * _DISPLAY_SCALE
	_grid.color = _DEFAULT_GRID_COLOR  # the editor overrides via set_grid_color; this is the standalone default
	_stage_area.add_child(_grid)

	_layer = Control.new()
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage_area.add_child(_layer)

	# Re-centre + redraw when this control is laid out / resized (its size is 0 until the first
	# layout pass, so the initial set_model render lands centred once a real size arrives).
	resized.connect(_render)


## Point the view at a model array and select an index (called when entering Stage mode, or after
## NEW/OPEN replaces the working project so the old array reference is stale). Re-renders.
func set_model(sprites: Array, selected: int) -> void:
	_sprites = sprites
	_selected = selected
	_render()


## Change only the selection (called when the sprite selector changes while in Stage mode). The
## model reference is unchanged; re-render to move the outline/handles.
func set_selected(index: int) -> void:
	_selected = index
	_render()


## Re-render from the current data without otherwise touching it — the editor calls this after an
## inspector edit so the on-stage rectangle reflects the new geometry/colour.
func refresh() -> void:
	_render()


## --- Stage settings the editor drives (M27) --------------------------------

## Recolour the stage backdrop (the project's background setting). Live — the stylebox is a resource,
## so updating bg_color repaints without a rebuild.
func set_background(color: Color) -> void:
	if _stage_box:
		_stage_box.bg_color = color


## Show or hide the alignment grid. Visual only — does not touch sprite geometry.
func set_grid_show(shown: bool) -> void:
	if _grid:
		_grid.show_grid = shown
		_grid.queue_redraw()


## Recolour the alignment grid.
func set_grid_color(color: Color) -> void:
	if _grid:
		_grid.color = color
		_grid.queue_redraw()


## Toggle snap-to-grid for drags. Deliberately does **not** re-snap the existing sprites — snapping
## is applied only when the user next drags (the M27 brief), so flipping this just stores the flag.
func set_grid_snap(snap: bool) -> void:
	_grid_snap = snap


# --- Rendering -------------------------------------------------------------

## Rebuild the stage from the data: centre the stage region, then draw one rectangle per sprite and,
## on the selected sprite, a selection outline plus a single bottom-right resize handle. The data is
## the single source of truth, so this runs after every change (drag, inspector edit, selection).
func _render() -> void:
	if _stage_area == null:
		return
	# Centre the stage region in whatever space the layout gave us (clamped so it never goes
	# negative when the control is briefly smaller than the region).
	var region := _STAGE_SIZE * _DISPLAY_SCALE
	var origin := (size - region) * 0.5
	_stage_area.position = Vector2(maxf(origin.x, 0.0), maxf(origin.y, 0.0))

	for child in _layer.get_children():
		child.queue_free()

	for i in _sprites.size():
		var entry: Dictionary = _sprites[i]
		var rect := _display_rect(entry)
		# The sprite body: a panel filled with the sprite's colour, with a faint border so a tiny or
		# fully-transparent sprite (the 1x1 HUDs, "#ffffff00") is still visible and discoverable.
		var panel := Panel.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.position = rect.position
		panel.size = rect.size
		panel.set_meta("sprite_index", i)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(String(entry.get("color", "#cccccc")))
		sb.border_color = Color(1, 1, 1, 0.25)
		sb.set_border_width_all(1)
		panel.add_theme_stylebox_override("panel", sb)
		_layer.add_child(panel)

	# The selection overlay is drawn last so it sits above every sprite. A single resize handle on the
	# bottom-right corner (M27): resize keeps the sprite's centre — its model position — fixed, so a
	# lone corner is enough and the position never shifts while you resize (the M27 brief).
	if _selected >= 0 and _selected < _sprites.size():
		var sel := _display_rect(_sprites[_selected])
		_add_selection_outline(sel)
		_add_handle(sel, Vector2(1, 1))


## The selection outline — a bright, fill-less border around the selected sprite's rect.
func _add_selection_outline(rect: Rect2) -> void:
	var outline := Panel.new()
	outline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outline.position = rect.position
	outline.size = rect.size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color("#ffd24d")  # the canvas's snap-highlight yellow
	sb.set_border_width_all(2)
	outline.add_theme_stylebox_override("panel", sb)
	_layer.add_child(outline)


## A small square resize handle centred on one corner of the selected sprite's rect. `corner` is a
## sign vector (±1, ±1) picking which corner; it is stamped as meta so the press handler can tell a
## handle grab from a body grab (the corner itself doesn't affect the resize — we keep the centre
## fixed and derive w/h from the cursor's distance to it).
func _add_handle(rect: Rect2, corner: Vector2) -> void:
	var c := rect.position + rect.size * (corner * 0.5 + Vector2(0.5, 0.5))  # the chosen corner point
	var handle := Panel.new()
	handle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	handle.position = c - Vector2(_HANDLE, _HANDLE) * 0.5
	handle.size = Vector2(_HANDLE, _HANDLE)
	handle.set_meta("handle_corner", corner)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#ffd24d")
	sb.border_color = Color("#0c0c12")
	sb.set_border_width_all(1)
	handle.add_theme_stylebox_override("panel", sb)
	_layer.add_child(handle)


## A sprite's display rectangle, local to the stage region: centred on its model position (a sprite's
## world box is centred on its node position — the same convention the runtime's collision uses),
## scaled by _DISPLAY_SCALE.
func _display_rect(entry: Dictionary) -> Rect2:
	var w := float(entry.get("w", 1)) * _DISPLAY_SCALE
	var h := float(entry.get("h", 1)) * _DISPLAY_SCALE
	var cx := float(entry.get("x", 0)) * _DISPLAY_SCALE
	var cy := float(entry.get("y", 0)) * _DISPLAY_SCALE
	return Rect2(cx - w * 0.5, cy - h * 0.5, w, h)


# --- Input -----------------------------------------------------------------

## Drive selection/drag from _input (before GUI input) with our own global hit-testing, mirroring
## block_canvas. We only consume the event when we act on it, so a press that misses every sprite
## (e.g. on the inspector beside us) falls through untouched.
func _input(event: InputEvent) -> void:
	# This view shares the OS window with the block canvas/palette and still receives _input while
	# hidden (Stage<->Blocks toggle); ignore events unless we're the visible surface, so a press in
	# Blocks mode can't grab a stale sprite rect here.
	if not is_visible_in_tree():
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _state == _IDLE:
			var hit := _hit(event.position)
			if hit.is_empty():
				return  # missed every sprite/handle — let the press fall through
			_state = _PENDING
			_press_pos = event.position
			_pending = hit
			get_viewport().set_input_as_handled()
		elif not event.pressed:
			if _state == _DRAGGING:
				_end_drag()
				get_viewport().set_input_as_handled()
			elif _state == _PENDING:
				# A plain click, never dragged: select the sprite under the press.
				_select(int(_pending["index"]))
				_state = _IDLE
				_pending = {}
	elif event is InputEventMouseMotion:
		if _state == _PENDING and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			_begin_drag()
			_update_drag(event.position)
			get_viewport().set_input_as_handled()
		elif _state == _DRAGGING:
			_update_drag(event.position)
			get_viewport().set_input_as_handled()


## What is under a global point: a resize handle of the selected sprite (checked first, the most
## specific target — cf. block_canvas checking _reporter_at before _block_at), else the topmost
## sprite body (last-drawn wins on overlap), else {}. Returns {index, mode, corner?}.
func _hit(global_point: Vector2) -> Dictionary:
	for handle in _layer.get_children():
		if handle.has_meta("handle_corner") and (handle as Control).get_global_rect().has_point(global_point):
			return {"index": _selected, "mode": "resize", "corner": handle.get_meta("handle_corner")}
	var index := -1
	for panel in _layer.get_children():
		if panel.has_meta("sprite_index") and (panel as Control).get_global_rect().has_point(global_point):
			index = int(panel.get_meta("sprite_index"))  # last match = topmost
	if index >= 0:
		return {"index": index, "mode": "move"}
	return {}


## Select a sprite via the editor's normal flow (on_pick routes through the selector + _show), so
## _current, the selector, the (hidden) canvas, and our highlight all stay consistent. We also set
## _selected locally so the overlay is right even if there is no editor wired.
func _select(index: int) -> void:
	_selected = index
	if on_pick.is_valid():
		on_pick.call(index)
	else:
		_render()


# --- Drag lifecycle --------------------------------------------------------

## Start a move or resize. A drag that begins on a sprite also selects it (Scratch's press-drag both
## moves and selects), so the inspector/handles follow. For a move we record the grab offset in model
## space so the sprite tracks the cursor without snapping its centre to it.
func _begin_drag() -> void:
	_drag_index = int(_pending["index"])
	_drag_mode = String(_pending["mode"])
	if _drag_index != _selected:
		_select(_drag_index)
	if _drag_mode == "move":
		var entry: Dictionary = _sprites[_drag_index]
		var centre := Vector2(float(entry["x"]), float(entry["y"]))
		_grab_offset_model = centre - _global_to_model(_press_pos)
	_state = _DRAGGING


## Apply the drag to the model and re-render. A move shifts the entry's x/y; a resize keeps the
## centre (the position) fixed and sets w/h from the dragged corner's distance to it, clamped to
## _MIN_DIM. Both go through _snap_model, which snaps to the grid when Snap is on (else rounds to the
## nearest whole pixel) — so the model stays the int shape PongScripts uses and Stage reads with
## int(...). The editor's inspector tracks via the on_geometry_changed callback.
func _update_drag(global_point: Vector2) -> void:
	if _drag_index < 0 or _drag_index >= _sprites.size():
		return
	var entry: Dictionary = _sprites[_drag_index]
	var m := _global_to_model(global_point)
	if _drag_mode == "move":
		# Snap the sprite's centre (its position) to the grid so the position lands on a grid line.
		var centre := m + _grab_offset_model
		entry["x"] = _snap_model(centre.x)
		entry["y"] = _snap_model(centre.y)
	else:  # resize about the fixed centre
		# Snap the dragged corner (the handle) to the grid, then derive w/h from its distance to the
		# fixed centre — so the handle lands on a grid line and the centre/position never moves.
		var cx := float(entry["x"])
		var cy := float(entry["y"])
		entry["w"] = maxi(_MIN_DIM, roundi(absf(_snap_model(m.x) - cx) * 2.0))
		entry["h"] = maxi(_MIN_DIM, roundi(absf(_snap_model(m.y) - cy) * 2.0))
	_render()
	if on_geometry_changed.is_valid():
		on_geometry_changed.call(_drag_index)


## Finish a drag — the geometry was written live, so this just resets the state machine.
func _end_drag() -> void:
	_state = _IDLE
	_pending = {}
	_drag_mode = ""
	_drag_index = -1


## A global point expressed in stage model coordinates: subtract the stage region's global origin,
## then divide out the display scale. The inverse of _display_rect's mapping.
func _global_to_model(global_point: Vector2) -> Vector2:
	var local := global_point - _stage_area.get_global_rect().position
	return local / _DISPLAY_SCALE


## Round a model coordinate to the grid when snap is on (nearest multiple of _GRID_STEP), else to the
## nearest whole pixel (the model's int shape). Both paths return an int — the shape PongScripts uses
## and Stage reads with int(...).
func _snap_model(value: float) -> int:
	if _grid_snap:
		return roundi(value / float(_GRID_STEP)) * _GRID_STEP
	return roundi(value)
