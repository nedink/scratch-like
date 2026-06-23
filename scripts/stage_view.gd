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
## Resize anchors the top-left corner by default (the sprite grows right/down), or about the centre
## while Alt is held. Independent w/h by default; **holding Shift locks the aspect ratio** to the
## sprite's proportions at the start of the drag (M28) — composing with Alt, so Shift+Alt is an
## aspect-locked resize about the centre. The two modifiers follow the same chrome-less, polled-each-
## frame idiom (no UI toggle), mirroring Alt-for-centre.
##
## What it deliberately leaves out (deferred): a live embedded *run* of the game (that needs the
## runtime in a SubViewport, a larger restructure).

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

## Default grid spacing in **model** pixels (M27). Drawn lines (and snapping) step by this much.
## 8 is a fine grid you can still see at _DISPLAY_SCALE and snap meaningfully to (the model is
## integer-valued, so a step finer than 1 buys nothing the round-to-int doesn't). The user can
## change it from the inspector via set_grid_step.
const _DEFAULT_GRID_STEP := 8

## The starting grid colour — a soft sky blue at low alpha, so the overlay reads as a faint guide
## over the dark stage rather than a wash. The user can recolour it from the inspector.
const _DEFAULT_GRID_COLOR := Color(0.529, 0.808, 0.980, 0.35)

## The starting stage background — opaque black (the editor seeds the real value from the project,
## so this is only the value shown before that injection).
const _DEFAULT_BACKGROUND := Color("#000000ff")


## A full-view custom-draw layer that paints the **whole world** (M39): the dark surrounding space is
## the StageView backdrop, and over it this draws the fine alignment grid spanning the entire view,
## the 480x352 screen region **tiled in all directions** as a grid of adjacent screen spaces, and the
## one **default screen highlighted** (filled with the project background + a bright boundary). It is
## a direct child of StageView (full rect, **not** panned), so it always covers the visible area no
## matter how far the world is panned; instead of moving, it redraws aligned to `world_origin` — the
## display-px position of world (0,0) within the view, i.e. the pan. The editor toggles the fine grid
## and recolours via StageView's set_grid_* / set_background setters, which queue_redraw here.
class _GridLayer:
	extends Control
	# Fine alignment grid (M27). Default mirrors StageView._DEFAULT_GRID_COLOR (a bare literal — an inner
	# class can't reference the outer class's constants by name). The editor overwrites via set_grid_color.
	var color: Color = Color(0.529, 0.808, 0.980, 0.35)
	var step: float = 1.0   # display px between fine grid lines (model _grid_step * _DISPLAY_SCALE)
	var show_grid: bool = true

	# Screen-cell overlay (M39). `world_origin` is the pan — the display-px position of world (0,0) in
	# this pan-fixed layer; `cell` is the 480x352 screen in display px; `bg_color` fills the highlighted
	# origin (default) screen, set from the project background.
	var world_origin: Vector2 = Vector2.ZERO
	var cell: Vector2 = Vector2.ONE
	var bg_color: Color = Color("#000000ff")
	# The screen-boundary guide line (matches StageView's old _stage_box border): bright for the default
	# screen, the same hue dimmed for the tiled adjacent screens.
	const _BOUNDARY := Color("#4ad0ff")
	const _BOUNDARY_DIM := Color(0.29, 0.816, 1.0, 0.4)

	func _draw() -> void:
		if cell.x <= 0.0 or cell.y <= 0.0:
			return
		# 1. The highlighted default screen: fill it with the project background so it reads as the
		#    "live" screen against the dark surrounding world.
		var origin_rect := Rect2(world_origin, cell)
		draw_rect(origin_rect, bg_color)
		# 2. The fine alignment grid, world-aligned and spanning the whole view (M39 — continues past
		#    the screen in every direction). fposmod aligns the first line to the world grid under any pan.
		if show_grid and step > 0.0:
			var x := fposmod(world_origin.x, step)
			while x < size.x:
				draw_line(Vector2(x, 0.0), Vector2(x, size.y), color, 1.0)
				x += step
			var y := fposmod(world_origin.y, step)
			while y < size.y:
				draw_line(Vector2(0.0, y), Vector2(size.x, y), color, 1.0)
				y += step
		# 3. The screen-boundary indicator continued into a grid (M39): the 480x352 cell tiled in all
		#    directions, dimmed, so adjacent screen spaces are visible around the default one.
		var cx := fposmod(world_origin.x, cell.x)
		while cx < size.x:
			draw_line(Vector2(cx, 0.0), Vector2(cx, size.y), _BOUNDARY_DIM, 1.0)
			cx += cell.x
		var cy := fposmod(world_origin.y, cell.y)
		while cy < size.y:
			draw_line(Vector2(0.0, cy), Vector2(size.x, cy), _BOUNDARY_DIM, 1.0)
			cy += cell.y
		# 4. The default screen's own boundary, bright and drawn last so it stands out from the tiled
		#    neighbours — this is the highlight.
		draw_rect(origin_rect, _BOUNDARY, false, 2.0)

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

## The dark "outside-screen" backdrop filling this whole control (M37). The world is drawn over it,
## so the area *beyond* the 480x352 screen reads as out-of-bounds rather than empty.
var _backdrop: Panel

## The pannable world container (M37): every world-space node is a child, and the container is
## positioned at `_pan` (display px), so moving it scrolls the whole world at once. The pan is
## absorbed here, so _display_rect (world*scale) and the child get_global_rect() hit-tests need no
## pan term — the node tree carries it.
var _world: Control

## Holds the per-sprite rectangles and the selection overlay (outline + handles), all rebuilt in
## _render and hit-tested by get_global_rect — exactly like block_canvas._layer. A child of _world
## (so it pans) and **not clipped**, so a sprite outside the screen region is fully visible (M37).
var _layer: Control

## The world overlay layer (M37/M39): the fine alignment grid spanning the whole view, the screen
## region tiled in all directions, and the highlighted default screen (background fill + bright
## boundary). A direct child of StageView (full rect, **not** panned) — it redraws aligned to the pan
## rather than moving. The editor toggles/recolours it via the set_grid_* / set_background setters.
var _grid: _GridLayer

## Whether a drag snaps the changed value to the grid (M27). On by default; the editor's "Snap to
## grid" checkbox flips it. Applied only when the user actually drags — flipping it never re-snaps
## the existing sprites (per the M27 brief: "only when the user goes to make a change").
var _grid_snap: bool = true

## Grid spacing in **model** pixels (M27); the inspector's "Grid step" spinner drives it via
## set_grid_step. Both the drawn grid and snap-to-grid read this.
var _grid_step: int = _DEFAULT_GRID_STEP

## The world's pan offset in display px (M37) — _world.position. Set by recenter() (screen centred in
## the view) and dragged by a background pan. _pan_start captures it at the start of a pan drag.
var _pan: Vector2
var _pan_start: Vector2

var _state: int = _IDLE
var _press_pos: Vector2            # global position of the initial press
var _pending: Dictionary = {}      # {index, mode, corner?} of the sprite/handle pressed, or {mode:"pan"}
var _drag_mode: String = ""        # "move", "resize", or "pan"
var _drag_index: int = -1          # the sprite being dragged
var _grab_offset_model: Vector2    # (move) sprite centre minus the press point, in model space
var _resize_w0: float = 0.0        # (resize) the sprite's w/h at the start of the drag — the aspect
var _resize_h0: float = 0.0        #   ratio Shift locks to (captured once so int-rounding can't drift it)


func _ready() -> void:
	clip_contents = true
	# PASS (not STOP) so the wheel still reaches any enclosing container; we drive from _input and
	# do our own global hit-testing, same as block_canvas / block_palette.
	mouse_filter = Control.MOUSE_FILTER_PASS

	# The out-of-bounds backdrop: a dark panel filling the whole view, behind the world (M37). The
	# world (screen region + sprites) is drawn over it, so the area beyond the screen reads as
	# out-of-bounds rather than empty.
	_backdrop = Panel.new()
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	var backdrop_box := StyleBoxFlat.new()
	backdrop_box.bg_color = Color("#15151c")
	_backdrop.add_theme_stylebox_override("panel", backdrop_box)
	add_child(_backdrop)

	# The world overlay (M39): the fine grid + the tiled screen cells + the highlighted default screen,
	# all painted by one full-view, pan-fixed layer over the backdrop. It is NOT a child of _world — it
	# spans the whole view and redraws aligned to the pan (set via world_origin in _apply_pan), so the
	# grid and the screen tiling continue indefinitely however far the world is panned.
	_grid = _GridLayer.new()
	_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grid.step = _grid_step * _DISPLAY_SCALE
	_grid.color = _DEFAULT_GRID_COLOR  # the editor overrides via set_grid_color; this is the standalone default
	_grid.cell = _STAGE_SIZE * _DISPLAY_SCALE
	_grid.bg_color = _DEFAULT_BACKGROUND  # the editor overrides via set_background
	add_child(_grid)

	# The pannable world container (M37): positioned at _pan, holding the sprites.
	_world = Control.new()
	_world.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_world)

	# Sprites + selection overlay, drawn over the world overlay. A child of _world (so it pans) at the
	# world origin; positioned per-sprite at world*scale by _display_rect.
	_layer = Control.new()
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world.add_child(_layer)

	# Re-centre on the screen + redraw when this control is laid out / resized (its size is 0 until the
	# first layout pass, so the initial render lands centred once a real size arrives).
	resized.connect(recenter)


## Point the view at a model array and select an index (called when entering Stage mode, or after
## NEW/OPEN replaces the working project so the old array reference is stale). Re-renders.
func set_model(sprites: Array, selected: int) -> void:
	_sprites = sprites
	_selected = selected
	recenter()  # centre the screen in the view on entering Stage mode, then render


## Change only the selection (called when the sprite selector changes while in Stage mode). The
## model reference is unchanged; re-render to move the outline/handles.
func set_selected(index: int) -> void:
	_selected = index
	_render()


## Re-render from the current data without otherwise touching it — the editor calls this after an
## inspector edit so the on-stage rectangle reflects the new geometry/colour. Leaves the pan as-is.
func refresh() -> void:
	_render()


## Centre the 480x352 screen region in the view (M37) — the initial framing, and what the editor's
## "Recenter view" button restores after the user has panned around. A negative pan (view smaller
## than the screen region) is fine now that nothing clips to the screen. Re-renders.
func recenter() -> void:
	var region := _STAGE_SIZE * _DISPLAY_SCALE
	_pan = (size - region) * 0.5
	_apply_pan()
	_render()


## Push the current pan onto the world container, rounded so the world doesn't land on half-pixels.
## The pan-fixed grid overlay doesn't move — it redraws aligned to the same rounded pan (world_origin),
## so the grid and tiled screen cells stay pixel-aligned with the panned sprites (M39).
func _apply_pan() -> void:
	if _world:
		_world.position = _pan.round()
	if _grid:
		_grid.world_origin = _pan.round()
		_grid.queue_redraw()


## --- Stage settings the editor drives (M27) --------------------------------

## Recolour the stage backdrop (the project's background setting) — the fill of the highlighted
## default screen in the world overlay. Live: just update the field and redraw.
func set_background(color: Color) -> void:
	if _grid:
		_grid.bg_color = color
		_grid.queue_redraw()


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


## Set the grid spacing (model px). Updates the drawn grid live; the new step governs the user's next
## snapped drag (like set_grid_snap, it never re-snaps existing sprites). Clamped to a sane minimum.
func set_grid_step(step: int) -> void:
	_grid_step = maxi(1, step)
	if _grid:
		_grid.step = _grid_step * _DISPLAY_SCALE
		_grid.queue_redraw()


# --- Rendering -------------------------------------------------------------

## Rebuild the stage from the data: centre the stage region, then draw one rectangle per sprite and,
## on the selected sprite, a selection outline plus a single bottom-right resize handle. The data is
## the single source of truth, so this runs after every change (drag, inspector edit, selection).
func _render() -> void:
	if _world == null:
		return
	# Keep the world at the current pan (recenter / a pan drag set _pan; this re-asserts it after a
	# rebuild). We deliberately do NOT recompute the pan here, so a user pan survives a selection /
	# inspector-edit re-render — only recenter() (and resize) re-frames.
	_apply_pan()

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
	# bottom-right corner (M27): by default resize anchors the top-left and moves the right/bottom
	# edges (grows right/down), so the bottom-right corner is the natural handle; holding Alt resizes
	# about the centre instead.
	if _selected >= 0 and _selected < _sprites.size():
		var sel := _display_rect(_sprites[_selected])
		_add_selection_outline(sel)
		# Suppress the resize handle when the sprite has a painted costume (M45): its w/h are slaved
		# to the costume resolution (cw/ch), so a resize drag would desync the footprint from the
		# pixels. Resolution is changed in the Paint view, not here (resize-canvas is deferred).
		if not (_sprites[_selected] as Dictionary).has("costume"):
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
## handle grab from a body grab (the corner itself doesn't affect the resize — the dragged corner is
## the cursor; by default the top-left is anchored, or with Alt the centre is).
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
				# Missed every sprite/handle. A press inside our own rect starts a **pan** of the world
				# (M37); a press outside it (e.g. on the inspector beside us) falls through untouched.
				if not get_global_rect().has_point(event.position):
					return
				_state = _PENDING
				_press_pos = event.position
				_pending = {"mode": "pan"}
				_pan_start = _pan
				get_viewport().set_input_as_handled()
				return
			_state = _PENDING
			_press_pos = event.position
			_pending = hit
			get_viewport().set_input_as_handled()
		elif not event.pressed:
			if _state == _DRAGGING:
				_end_drag()
				get_viewport().set_input_as_handled()
			elif _state == _PENDING:
				# A plain click that never dragged: select the sprite under the press (a background
				# click — a pending pan — is a no-op, leaving the selection alone).
				if String(_pending.get("mode", "")) != "pan":
					_select(int(_pending["index"]))
				_state = _IDLE
				_pending = {}
	elif event is InputEventMouseMotion:
		if _state == _PENDING and event.position.distance_to(_press_pos) > DRAG_THRESHOLD:
			if String(_pending.get("mode", "")) == "pan":
				_state = _DRAGGING
				_drag_mode = "pan"
				_update_pan(event.position)
			else:
				_begin_drag()
				_update_drag(event.position)
			get_viewport().set_input_as_handled()
		elif _state == _DRAGGING:
			if _drag_mode == "pan":
				_update_pan(event.position)
			else:
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
	else:
		# Resize: capture the starting w/h so Shift-lock keeps the aspect of the *original* sprite for
		# the whole drag — recomputing the ratio from the (live-mutated, int-rounded) entry each frame
		# would let it drift. Guarded to >=1 so a 1x1 HUD still has a usable ratio.
		var entry: Dictionary = _sprites[_drag_index]
		_resize_w0 = maxf(1.0, float(entry["w"]))
		_resize_h0 = maxf(1.0, float(entry["h"]))
	_state = _DRAGGING


## Apply the drag to the model and re-render. A move shifts the entry's x/y; a resize moves only the
## right/bottom edges, keeping the **top-left corner anchored** (the sprite grows right and downward) —
## unless **Alt** is held, which resizes about the fixed centre (growing in all directions). Either
## resize locks to the sprite's starting aspect ratio while **Shift** is held (via _lock_aspect, M28).
## Both go through _snap_model, which snaps a corner to the grid when Snap is on (a move snaps the
## sprite's top-left corner, a resize the dragged corner; else rounds to the nearest whole pixel) — so
## the model stays the int shape PongScripts uses and Stage reads with
## int(...). The editor's inspector tracks via the on_geometry_changed callback.
func _update_drag(global_point: Vector2) -> void:
	if _drag_index < 0 or _drag_index >= _sprites.size():
		return
	var entry: Dictionary = _sprites[_drag_index]
	var m := _global_to_model(global_point)
	if _drag_mode == "move":
		# Snap the sprite's **top-left corner** to the grid (not its centre) so its visible edges land on
		# grid lines — the tile/image-editor convention, and consistent with how a resize snaps the
		# dragged corner. Snapping the centre only aligns the edges when w/h are even multiples of the
		# step. The model stores x/y as the centre, so we snap the corner then derive the centre back.
		var centre := m + _grab_offset_model
		var left := _snap_model(centre.x - float(entry["w"]) * 0.5)
		var top := _snap_model(centre.y - float(entry["h"]) * 0.5)
		entry["x"] = roundi(left + float(entry["w"]) * 0.5)
		entry["y"] = roundi(top + float(entry["h"]) * 0.5)
	elif Input.is_key_pressed(KEY_ALT):
		# Alt: resize about the fixed centre — derive w/h from the dragged corner's distance to the
		# centre (doubled), so the sprite grows symmetrically and the position never moves.
		var cx := float(entry["x"])
		var cy := float(entry["y"])
		var dims := _lock_aspect(absf(_snap_model(m.x) - cx) * 2.0, absf(_snap_model(m.y) - cy) * 2.0)
		entry["w"] = maxi(_MIN_DIM, roundi(dims.x))
		entry["h"] = maxi(_MIN_DIM, roundi(dims.y))
	else:
		# Default: anchor the top-left corner and move only the right/bottom edges, so the sprite is
		# resized rightward/downward. The model stores x/y as the *centre*, so as w/h grow the centre
		# shifts to keep the top-left fixed.
		var left := float(entry["x"]) - float(entry["w"]) * 0.5
		var top := float(entry["y"]) - float(entry["h"]) * 0.5
		var dims := _lock_aspect(_snap_model(m.x) - left, _snap_model(m.y) - top)
		var new_w := maxi(_MIN_DIM, roundi(dims.x))
		var new_h := maxi(_MIN_DIM, roundi(dims.y))
		entry["w"] = new_w
		entry["h"] = new_h
		entry["x"] = roundi(left + new_w * 0.5)
		entry["y"] = roundi(top + new_h * 0.5)
	_render()
	if on_geometry_changed.is_valid():
		on_geometry_changed.call(_drag_index)


## Pan the world to follow the cursor (M37): offset the captured pan by how far the cursor has moved
## since the press. Only _world's position changes — no model data is touched.
func _update_pan(global_point: Vector2) -> void:
	_pan = _pan_start + (global_point - _press_pos)
	_apply_pan()


## Finish a drag — the geometry was written live, so this just resets the state machine.
func _end_drag() -> void:
	_state = _IDLE
	_pending = {}
	_drag_mode = ""
	_drag_index = -1


## A global point expressed in stage model coordinates: subtract the world container's global origin
## (which already includes the pan), then divide out the display scale. The inverse of _display_rect's
## mapping (_display_rect is world*scale local to _world, so the pan is absorbed by _world's position).
func _global_to_model(global_point: Vector2) -> Vector2:
	var local := global_point - _world.global_position
	return local / _DISPLAY_SCALE


## Constrain a proposed (w, h) to the sprite's starting aspect ratio while **Shift** is held (M28),
## else pass it through unchanged. We scale the original w0/h0 by whichever proposed axis grew more
## (max of the two ratios), so the dragged corner leads — the image-editor convention. The driving
## axis stays grid-snapped (its value came through _snap_model); the derived axis follows the ratio
## and so may land off-grid — the aspect constraint deliberately wins over snap. Returns floats; the
## caller rounds + clamps to _MIN_DIM, exactly as the unlocked path does.
func _lock_aspect(w: float, h: float) -> Vector2:
	if not Input.is_key_pressed(KEY_SHIFT) or _resize_w0 <= 0.0 or _resize_h0 <= 0.0:
		return Vector2(w, h)
	var s := maxf(w / _resize_w0, h / _resize_h0)
	return Vector2(_resize_w0 * s, _resize_h0 * s)


## Round a model coordinate to the grid when snap is on (nearest multiple of _grid_step), else to the
## nearest whole pixel (the model's int shape). Both paths return an int — the shape PongScripts uses
## and Stage reads with int(...).
func _snap_model(value: float) -> int:
	if _grid_snap:
		return roundi(value / float(_grid_step)) * _grid_step
	return roundi(value)
