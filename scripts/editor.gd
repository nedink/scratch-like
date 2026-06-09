class_name BlockEditor
extends Control

## The editor scene root — the project's front door (M8), now with a palette of new
## blocks (M11) beside the draggable canvas (M9).
##
## Built runtime-first toward a drag-and-drop block editor: M8 a read-only renderer; M9
## interactive (pick a block up, drag it, snap it in/out of a stack); M10 RUN plays the
## edits; M11 a **palette** to drag *new* blocks from, so a script can be assembled from
## scratch. The canvas interaction lives in block_canvas.gd and the palette in
## block_palette.gd; this scene root is the chrome around them (a sprite selector and a
## RUN button) plus the workspace layout (palette | canvas).
##
## F5 launches *this* instead of the game; the game is reached through the RUN button,
## which switches to main.tscn (the Stage) and hands it the *edited* scripts (M10).
##
## The chrome — the fixed-shape layout (backdrop, top bar, palette | canvas workspace) and
## the three variable dialogs (Make / Rename / Delete) — is **declared in editor.tscn**, since
## none of it is data-driven; this script reaches those nodes by unique name (`%`) and supplies
## only the dynamic parts (the selector's items, the signal wiring, the dialog logic). The
## *contents* of the palette and canvas, which are generated from block data, stay in code
## (block_palette.gd / block_canvas.gd). (stage.gd still builds its sprites in code — that set
## is headed for the data-owned project model, not the scene editor.)

## The game scene the RUN button launches. main.tscn is unchanged from M7 — it is
## just no longer the project's main_scene (the editor is); it is the *game* now.
const _GAME_SCENE := "res://main.tscn"

## The editor's logical resolution (M26) — the coordinate space its chrome lays out in, independent
## of the runtime's fixed 480x352. Larger than 480x352 (more workspace) but smaller than a typical
## screen's raw pixels (so blocks/text scale up to a readable size rather than shrinking). On a
## 1920x1080 screen this is a 2x upscale. Bump it for more room (smaller blocks) or shrink it for
## bigger blocks (less room) — it is the one knob for the editor's zoom. See _ready.
const _EDITOR_SIZE := Vector2i(960, 540)

## User zoom (pinch / Ctrl+scroll). The window's `content_scale_factor` multiplies *on top of*
## the M26 `_EDITOR_SIZE` fit (1.0 = the default layout); lowering it zooms the whole editor
## **out** — smaller blocks, more workspace visible — which is what a crowded canvas wants. We
## only allow zooming out from the default (cap at 1.0) "a few stops" down to `_ZOOM_MIN`. Changing
## the factor is hit-test-safe: the engine transforms GUI event positions into the same canvas
## space the Controls lay out in, so `BlockCanvas`'s event.position-vs-get_global_rect() tests
## (and the palette's / stage view's) stay consistent whatever the factor. See _input.
const _ZOOM_MIN := 0.5
const _ZOOM_MAX := 1.0
const _ZOOM_STEP := 0.1
var _zoom := 1.0

## The starting folder the SAVE/OPEN browser opens in when no project is bound yet (M22) — the project
## directory, a sensible, findable default. We deliberately impose *no* dedicated saves folder: the
## file browser uses full filesystem access, so the user picks where a project lives (the repo, the
## Desktop, anywhere) and that choice is theirs. At runtime Godot's FileDialog has no remembered
## default, so we set this explicitly; after the first save the dialog reopens at the bound file's
## folder. `globalize_path` resolves `res://` to the absolute OS path filesystem-access needs.
func _default_browse_dir() -> String:
	return ProjectSettings.globalize_path("res://")

## Display name -> the sprite's block script, for the selector. This mirrors the
## name->script wiring inline in stage.gd._ready; the small duplication is fine for now.
## A later milestone where the editor *owns* the project model would unify the two.
## Populated in _ready (PongScripts calls aren't const-safe). As of M10 this is the
## **living project**: switching sprites (and RUN) persists the canvas's edits back
## here, so every sprite's edits accumulate for the session.
var _scripts: Array = []

## The currently-selected sprite index, so we know which entry to persist edits into
## before switching away. -1 until the first script loads.
var _current: int = -1

## The interactive block canvas (M9): drag/snap lives here. Reloaded on selection.
## A scene node (editor.tscn), grabbed by unique name.
@onready var _canvas: BlockCanvas = %Canvas

## The block palette (M11): the source of *new* blocks. Hands fresh blocks to the canvas.
@onready var _palette: BlockPalette = %Palette

## The palette's ScrollContainer — also the canvas's trash region (M16): a block dragged
## back over it is deleted. (The palette VBox lives inside it.)
@onready var _palette_scroll: ScrollContainer = %PaletteScroll

## The top-bar widgets we wire in _ready: the sprite selector (populated from _scripts) and RUN.
@onready var _selector: OptionButton = %SpriteSelector
@onready var _run_button: Button = %RunButton

## The stage (scene) editor chrome (M27): a top-bar toggle that swaps the workspace between Blocks
## (palette | canvas) and Stage (the stage view + inspector), the stage view itself, and the
## inspector's per-sprite geometry/colour widgets. The stage view edits a sprite's placeholder
## geometry directly; the canvas scroll is hidden while it is up (Scratch's Code/Costumes tabs).
@onready var _view_toggle: Button = %ViewToggle
@onready var _canvas_scroll: ScrollContainer = %CanvasScroll
@onready var _stage_container: HBoxContainer = %StageContainer
@onready var _stage_view: StageView = %StageView
@onready var _insp_name: Label = %InspName
@onready var _insp_x: SpinBox = %InspX
@onready var _insp_y: SpinBox = %InspY
@onready var _insp_w: SpinBox = %InspW
@onready var _insp_h: SpinBox = %InspH
@onready var _insp_color: ColorPickerButton = %InspColor

## Stage-level settings in the inspector (M27): the project's background colour, plus the grid's
## show / snap toggles, colour, and step. All are real project properties (seeded from PongScripts,
## persisted in the .json, synced to these controls on every project load) — the background also
## drives the running game at RUN; the grid settings are editor authoring aids the project remembers.
@onready var _bg_color: ColorPickerButton = %BgColor
@onready var _grid_show: CheckBox = %GridShow
@onready var _grid_snap: CheckBox = %GridSnap
@onready var _grid_color: ColorPickerButton = %GridColor
@onready var _grid_step: SpinBox = %GridStep

## The project's stage background colour as a hex string (M27) — a real project property, the
## stage-level counterpart of _scripts / _variables. Seeded from PongScripts.background(), edited via
## the inspector's Background picker (_on_insp_bg_color), saved under a top-level "background" key, and
## handed to the Stage at RUN (project_background). _read_project defaults it for a pre-M27 save.
var _background: String = ""

## The project's stage-editor grid settings (M27) — {show, snap, color (hex), step} — a project
## property like _background. Seeded from PongScripts.grid(), edited via the inspector's grid controls
## (_on_grid_*), saved under a top-level "grid" key, and synced to the controls + stage view on every
## project load (_sync_grid). _read_project defaults it for a pre-grid save. Editor-only: unlike the
## background it isn't handed to the running game (the grid is an authoring aid, not part of the scene).
var _grid_settings: Dictionary = {}

## True while the Stage view is showing (vs the block canvas). The toggle flips it.
var _stage_mode: bool = false

## Set while _sync_inspector is loading the spin boxes / colour picker from the model, so their
## value_changed/color_changed signals don't fire back and re-write the model with what we just read.
var _loading_inspector: bool = false

## Project persistence chrome (M22): the title (rewritten to show the open project's name), the
## NEW / OPEN / SAVE buttons, and the shared FileDialog the latter two pop. NEW reloads the
## in-code demo; OPEN / SAVE browse the filesystem for `.json` project files. One FileDialog serves
## both actions — `_file_action` records which is in flight (the rename/delete dialogs use the same
## "state var carries the payload the confirmed signal doesn't" idiom), and `_current_path` is the
## file the working project is bound to ("" for the unsaved demo), so SAVE can pre-fill its name.
@onready var _title: Label = %Title
@onready var _new_button: Button = %NewButton
@onready var _open_button: Button = %OpenButton
@onready var _save_button: Button = %SaveButton
@onready var _file_dialog: FileDialog = %FileDialog
var _file_action: String = ""
var _current_path: String = ""

## The project's variable model (M20) — the editor-owned, **mutable** counterpart of _scripts.
## Seeded from PongScripts.variables() (the single declaration the runtime also reads), then
## extended by the "Make a Variable" button, which appends a fresh {name, value, scope} entry.
## _variables_in_scope filters this per sprite for the `{name}` dropdowns; _on_run hands it to
## the Stage so a variable made here is seeded at RUN. Through M19 the editor read
## PongScripts.variables() live each call — fine while read-only; M20 needs a stable store to
## append to, so the editor now owns this copy.
var _variables: Array = []

## The "Make a Variable" dialog (M20) and its inputs: a name field and a scope selector
## ("For all sprites" → a global / "For this sprite only" → a local of the edited sprite).
## Declared in editor.tscn and reused; the palette button pops it via _make_variable.
@onready var _var_dialog: ConfirmationDialog = %VarDialog
@onready var _var_name_edit: LineEdit = %VarNameEdit
@onready var _var_scope: OptionButton = %VarScope

## The rename / delete dialogs (M21), declared in editor.tscn and reused. A palette variable row's
## menu pops one of these via _rename_variable / _delete_variable; _renaming / _deleting hold the
## name the open dialog is acting on (the dialogs' confirmed signals carry no payload). The delete
## label is rewritten per-invocation to report the usage count.
@onready var _rename_dialog: ConfirmationDialog = %RenameDialog
@onready var _rename_edit: LineEdit = %RenameEdit
var _renaming: String = ""
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog
@onready var _delete_label: Label = %DeleteLabel
var _deleting: String = ""

## Add / Delete **sprite** chrome (M24): the top-bar buttons beside the selector, and the two dialogs
## (declared in editor.tscn, reused). Add pops a name prompt; Delete pops a confirmation whose label is
## rewritten per-invocation with the count of locals that go with the sprite. `_deleting_sprite` holds
## the name the open delete dialog acts on (the confirmed signal carries no payload — the same state-var
## idiom the variable rename/delete dialogs use).
@onready var _add_sprite_button: Button = %AddSpriteButton
@onready var _del_sprite_button: Button = %DelSpriteButton
@onready var _sprite_dialog: ConfirmationDialog = %SpriteDialog
@onready var _sprite_name_edit: LineEdit = %SpriteNameEdit
@onready var _del_sprite_dialog: ConfirmationDialog = %DelSpriteDialog
@onready var _del_sprite_label: Label = %DelSpriteLabel
var _deleting_sprite: String = ""

## Rename **sprite** chrome (M25): the top-bar Rename Sprite button and its dialog (declared in
## editor.tscn, reused). The button pops a name prompt pre-filled with the selected sprite's name;
## `_renaming_sprite` holds the name the open dialog acts on (the confirmed signal carries no payload —
## the same state-var idiom the variable rename dialog and the sprite delete dialog use). This is the
## sprite analog of M21's variable rename: confirming cascades the new name across every script's
## `touching_sprite?` references and every variable scoped to the sprite (its locals).
@onready var _rename_sprite_button: Button = %RenameSpriteButton
@onready var _rename_sprite_dialog: ConfirmationDialog = %RenameSpriteDialog
@onready var _rename_sprite_edit: LineEdit = %RenameSpriteEdit
var _renaming_sprite: String = ""

## Make a Block chrome (M30): the palette's "Make a Block" button pops this name dialog; on confirm
## a `define {name}` hat is added to the canvas and the sprite's custom-block list re-derived. The
## dialog is declared in editor.tscn and reused, like the variable/sprite name dialogs. Custom blocks
## are derived from the sprite's script (the `define` hats), not a separate model — so there is no
## stored list to mutate, only the canvas to add to.
@onready var _block_dialog: ConfirmationDialog = %BlockDialog
@onready var _block_name_edit: LineEdit = %BlockNameEdit

## A freshly added sprite's placeholder geometry (M24): a small grey square at the stage center. It is
## just a starting placeholder — real positioning is blocks (a `go_to` in the sprite's script, as the
## ball does), so there is no UI yet to move/resize/recolour it (M25 added rename but left geometry
## editing deferred). Also the fill values _read_project defaults a pre-M24 saved entry to.
const _DEFAULT_SPRITE := {"x": 240, "y": 180, "w": 24, "h": 24, "color": "#cccccc"}


func _ready() -> void:
	# Lay the editor chrome out against its own logical resolution (M26) — bigger than the runtime's
	# fixed 480x352 (so the workspace has room) but well under the raw window pixels (so blocks/text
	# don't shrink to nothing on a large screen). We keep VIEWPORT mode (the same stretch the canvas's
	# manual global-coordinate hit-testing was written against) at _EDITOR_SIZE, with EXPAND so the
	# chrome fills the whole window (no letterbox) and FRACTIONAL stretch so it scales smoothly to any
	# screen. This also *resets* the window after a RUN: stage.gd flips it to a 480x352 INTEGER viewport
	# for the game, and ESC returns here, so we restore the editor's policy every time _ready runs.
	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	win.content_scale_size = _EDITOR_SIZE
	win.content_scale_factor = 1.0

	# Land on the in-code demo (the stock Pong project). It is the unsaved default — bound to no
	# file — so it is always reachable and never overwritten by a saved project (M22).
	_seed_demo()

	# Wire the signals/callbacks once (the *contents* below re-render per project, but these
	# connections are set up a single time). The layout and dialogs are declared in editor.tscn;
	# the @onready vars already point at them — we supply only the dynamic wiring.
	_selector.item_selected.connect(_on_select)
	_run_button.pressed.connect(_on_run)
	# Project persistence (M22): NEW reloads the demo, OPEN/SAVE pop the file browser.
	_new_button.pressed.connect(_on_new)
	_open_button.pressed.connect(_on_open)
	_save_button.pressed.connect(_on_save)
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = false
	_file_dialog.add_filter("*.json", "Project files")
	_file_dialog.file_selected.connect(_on_file_selected)

	# The palette feeds fresh blocks to the canvas (M11) and doubles as the canvas's trash:
	# dragging a block back over the palette region deletes it (M16, Scratch's own gesture).
	# Its "Make a Variable" button (M20) calls back here to mint a new variable.
	_palette._canvas = _canvas
	_palette._on_make_variable = _make_variable
	# Each in-scope variable's palette row (M21) calls back here to rename or delete it.
	_palette._on_rename_variable = _rename_variable
	_palette._on_delete_variable = _delete_variable
	# The palette's "Make a Block" button (M30) calls back here to mint a custom block (a `define` hat).
	_palette._on_make_block = _make_block
	_canvas._trash = _palette_scroll

	# Stage (scene) editor (M27): the toggle swaps Blocks <-> Stage; the stage view reports a clicked
	# sprite (on_pick, routed through the normal selection flow) and live geometry changes during a
	# drag (on_geometry_changed, so the inspector tracks); the inspector writes geometry/colour back.
	_view_toggle.pressed.connect(_toggle_view)
	_stage_view.on_pick = _on_stage_pick
	_stage_view.on_geometry_changed = _on_stage_geometry_changed
	_insp_x.value_changed.connect(_on_insp_x)
	_insp_y.value_changed.connect(_on_insp_y)
	_insp_w.value_changed.connect(_on_insp_w)
	_insp_h.value_changed.connect(_on_insp_h)
	_insp_color.color_changed.connect(_on_insp_color)

	# Stage-level settings (M27): the background picker and grid controls all write project properties
	# via editor handlers; both are synced to their controls + the stage view per project in
	# _load_project_into_ui (_sync_background / _sync_grid), so no up-front push is needed here.
	_bg_color.color_changed.connect(_on_insp_bg_color)
	_grid_show.toggled.connect(_on_grid_show)
	_grid_snap.toggled.connect(_on_grid_snap)
	_grid_color.color_changed.connect(_on_grid_color)
	_grid_step.value_changed.connect(_on_grid_step_changed)

	# Wire the scene's dialogs: their confirmed signal to the handler, and Enter in the text
	# field to confirm (register_text_enter, matching Scratch's quick flow). The delete dialog
	# has no text field — its body label is rewritten per-invocation in _delete_variable.
	_var_dialog.confirmed.connect(_on_new_variable_confirmed)
	_var_dialog.register_text_enter(_var_name_edit)
	_rename_dialog.confirmed.connect(_on_rename_confirmed)
	_rename_dialog.register_text_enter(_rename_edit)
	_delete_dialog.confirmed.connect(_on_delete_confirmed)

	# Add / Delete sprite (M24): the top-bar buttons and their dialogs. Add's name field confirms on
	# Enter (matching the variable dialogs); both dialogs' confirmed signal routes to its handler.
	_add_sprite_button.pressed.connect(_add_sprite_pressed)
	_del_sprite_button.pressed.connect(_del_sprite_pressed)
	_sprite_dialog.confirmed.connect(_on_new_sprite_confirmed)
	_sprite_dialog.register_text_enter(_sprite_name_edit)
	_del_sprite_dialog.confirmed.connect(_on_del_sprite_confirmed)
	# Rename sprite (M25): the button pops the name prompt, the dialog cascades the rename on confirm.
	_rename_sprite_button.pressed.connect(_rename_sprite_pressed)
	_rename_sprite_dialog.confirmed.connect(_on_rename_sprite_confirmed)
	_rename_sprite_dialog.register_text_enter(_rename_sprite_edit)
	# Make a Block (M30): the name dialog confirms on Enter (like the variable/sprite name dialogs).
	_block_dialog.confirmed.connect(_on_new_block_confirmed)
	_block_dialog.register_text_enter(_block_name_edit)

	# Populate the selector + canvas from the seeded project and show its first sprite.
	_load_project_into_ui()


## Editor zoom (M28-follow-on): pinch (trackpad magnify) or Ctrl+scroll zooms the whole editor
## out a few stops and back. `_input` (not `_unhandled_input`) so we get the wheel before the
## ScrollContainer would consume a plain scroll — but only with Ctrl held, so an unmodified wheel
## still scrolls the canvas/palette as before. A magnify gesture (no chord) zooms directly. We act
## only on these two events — never on a press/motion — so the canvas's / palette's own `_input`
## drag spine is untouched whatever the tree order.
func _input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		_apply_zoom(_zoom * event.factor)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.ctrl_pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_apply_zoom(_zoom + _ZOOM_STEP)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_apply_zoom(_zoom - _ZOOM_STEP)
			get_viewport().set_input_as_handled()


## Clamp the requested zoom to the allowed stops and push it to the shared window. Lower factor =
## zoomed out (smaller content, more room); 1.0 is the default fit. We cap at 1.0 (out-only).
func _apply_zoom(target: float) -> void:
	_zoom = clampf(target, _ZOOM_MIN, _ZOOM_MAX)
	get_window().content_scale_factor = _zoom


## ESC quits the program (in-game ESC instead drops back here — see Stage._unhandled_input).
## Unhandled-input, so an open dialog (its popup grabs ESC to cancel itself) or a focused field
## gets first crack; only an ESC nothing else claimed reaches here and exits.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		get_tree().quit()


## Seed the working project with the stock demo — the in-code PongScripts (M22, extracted from the
## original _ready). `_scripts` is the **living project** (M10): switching sprites and RUN persist
## the canvas's edits back here. As of M24 each `_scripts` entry is a full **sprite def** —
## {name, x, y, w, h, color, script} — so it owns the sprite's placeholder geometry too (the sprite
## counterpart of M18's variable model); the editor can add/delete entries from the UI.
## `_variables` is the editor-owned **mutable** variable model (M20),
## seeded from the one runtime declaration PongScripts.variables() (a fresh array each call, so the
## editor keeps its own copy to append to); _on_run hands it back to the Stage. Both are deep copies
## so editing never mutates the shared PongScripts builders.
func _seed_demo() -> void:
	# Each entry is now a full sprite def — name + placeholder geometry + script (M24) — sourced from
	# the one sprite model PongScripts.sprites(), the same declaration the Stage builds from, so the
	# editor and runtime can no longer drift on the sprite set (the sprite counterpart of M18's
	# variable unification). Deep-copied so editing never mutates the shared PongScripts builders.
	_scripts = PongScripts.sprites().duplicate(true)
	_variables = PongScripts.variables().duplicate(true)
	_background = PongScripts.background()
	_grid_settings = PongScripts.grid()


## Bring the current `_scripts` / `_variables` up in the UI (M22) — the shared path used on launch
## and after NEW / OPEN replace the working project. Repopulates the sprite selector, re-points the
## renderer's project model (sprite names + the index-0-scoped variable list — M17/M19; static on
## BlockView, like Stage.project_sprites) and shows the chosen sprite. Crucially it resets `_current`
## to -1 *before* _show, so _show's leading _persist_current() doesn't write the outgoing canvas
## (still showing the previous project) into the freshly loaded `_scripts`. _show then re-scopes the
## variables, rebuilds the palette, and loads the canvas.
## `select_index` (M24) is which sprite to land on — 0 for launch / NEW / OPEN (their default), but
## the new sprite after Add and a surviving neighbour after Delete, so the selector follows the edit.
func _load_project_into_ui(select_index := 0) -> void:
	_current = -1
	_selector.clear()
	for entry in _scripts:
		_selector.add_item(entry["name"])
	BlockView.project_sprites = _sprite_names()
	_update_title()
	_sync_background()  # NEW/OPEN may have changed the project's background; push it to the view + picker
	_sync_grid()        # likewise the grid settings (show/snap/colour/step) — push to the controls + view
	var index: int = clampi(select_index, 0, _scripts.size() - 1)
	_selector.select(index)
	_show(index)
	# NEW / OPEN replace _scripts with a fresh array, so re-point the stage view at it (set_selected
	# in _show only re-rendered the stale reference). A no-op in Blocks mode (re-pulled on toggle).
	if _stage_mode:
		_stage_view.set_model(_scripts, index)
		_sync_inspector()


## Load the script at `index` into the canvas, first persisting the outgoing sprite's
## edits so switching sprites doesn't discard them (M10 — edits are no longer a
## throwaway sandbox). The canvas works on a deep copy; _persist serializes it back.
func _show(index: int) -> void:
	_persist_current()
	_current = index
	# Re-scope the variable dropdowns to the sprite we're loading (M19): globals plus *this*
	# sprite's locals. Both the canvas (rendered next) and the palette's chips read
	# project_variables, so update it and rebuild the palette before the canvas renders — that
	# way editing the Ball shows `speed` in every menu and editing a paddle hides it.
	BlockView.project_variables = _variables_in_scope(_scripts[index]["name"])
	# Re-derive the sprite's custom blocks (M30) — the `define` hats in its script — so the palette's
	# `call` chips and any `call {name}` dropdown list this sprite's procedures (the per-sprite
	# custom-block twin of project_variables). Derived from the script being loaded, the same way the
	# variable list is scoped per sprite.
	BlockView.project_custom_blocks = _custom_blocks_in(_scripts[index]["script"])
	_palette.rebuild()
	_canvas.load_script(_scripts[index]["script"])
	# Keep the stage view's highlight + the inspector on the loaded sprite while Stage mode is up
	# (M27). The model reference is unchanged here, so set_selected (not set_model) suffices.
	if _stage_mode:
		_stage_view.set_selected(index)
		_sync_inspector()


func _on_select(index: int) -> void:
	_show(index)


# --- Stage (scene) editor (M27) --------------------------------------------

## Swap the workspace between Blocks (palette | canvas) and Stage (stage view + inspector). An
## HBoxContainer skips visible == false children, so hiding one mode lets the other fill the width.
## Entering Stage mode (re)points the stage view at the live model — it may have changed via the
## block side or an Add/Delete/Rename since we were last here — and loads the inspector.
func _toggle_view() -> void:
	_stage_mode = not _stage_mode
	_palette_scroll.visible = not _stage_mode
	_canvas_scroll.visible = not _stage_mode
	_stage_container.visible = _stage_mode
	_view_toggle.text = "Blocks" if _stage_mode else "Stage"
	if _stage_mode:
		_persist_current()  # fold any in-progress canvas edits back before we leave the canvas
		_stage_view.set_model(_scripts, _current)
		_sync_inspector()


## A sprite was clicked on the stage: select it through the normal flow (the selector + _show, which
## persists the outgoing canvas and loads the new sprite — correct even while the canvas is hidden),
## so Blocks mode shows the right sprite when we switch back. _show re-points the highlight + inspector.
func _on_stage_pick(index: int) -> void:
	if index != _current:
		_selector.select(index)
		_show(index)
	else:
		_stage_view.set_selected(index)
		_sync_inspector()


## A drag changed the dragged sprite's geometry; mirror it into the inspector if it's the selected
## one, so the x/y/w/h read-outs track live. The model write happened in the stage view itself.
func _on_stage_geometry_changed(index: int) -> void:
	if index == _current:
		_sync_inspector()


## Load the inspector widgets from the selected sprite's model entry. Guarded by _loading_inspector
## so setting the values doesn't fire the value_changed/color_changed writers back at the model.
func _sync_inspector() -> void:
	if _current < 0 or _current >= _scripts.size():
		return
	var entry: Dictionary = _scripts[_current]
	_loading_inspector = true
	_insp_name.text = "Sprite: %s" % entry["name"]
	_insp_x.value = float(entry.get("x", 0))
	_insp_y.value = float(entry.get("y", 0))
	_insp_w.value = float(entry.get("w", 1))
	_insp_h.value = float(entry.get("h", 1))
	_insp_color.color = Color(String(entry.get("color", "#cccccc")))
	_loading_inspector = false


## Write a geometry field into the selected sprite's entry (rounded to int, the model's shape) and
## re-render the stage. Skipped while the inspector is being loaded (so a read can't echo back).
func _write_geom(key: String, value: int) -> void:
	if _loading_inspector or _current < 0 or _current >= _scripts.size():
		return
	_scripts[_current][key] = value
	_stage_view.refresh()


func _on_insp_x(value: float) -> void:
	_write_geom("x", roundi(value))


func _on_insp_y(value: float) -> void:
	_write_geom("y", roundi(value))


func _on_insp_w(value: float) -> void:
	_write_geom("w", roundi(value))


func _on_insp_h(value: float) -> void:
	_write_geom("h", roundi(value))


## Write the colour picker's value back as the model's hex-string colour (M24's JSON-clean format),
## with alpha, then re-render. Skipped while loading (setting the picker mustn't echo back).
func _on_insp_color(color: Color) -> void:
	if _loading_inspector or _current < 0 or _current >= _scripts.size():
		return
	_scripts[_current]["color"] = "#" + color.to_html(true)
	_stage_view.refresh()


## Load the Background picker from the project's `_background` and apply it to the stage view (M27).
## Guarded by _loading_inspector so setting the picker can't echo back through _on_insp_bg_color. Run
## on every project load (launch / NEW / OPEN), like _sync_grid — both the background and the grid are
## project properties now, reloaded with the project rather than kept across it.
func _sync_background() -> void:
	_loading_inspector = true
	_bg_color.color = Color(_background)
	_loading_inspector = false
	_stage_view.set_background(Color(_background))


## Write the Background picker's value into the project setting (M27, hex with alpha — the JSON-clean
## format the sprite colours use) and recolour the stage view. It rides _write_project / _on_run like
## any project data. Skipped while the picker is being loaded (so a read can't echo back).
func _on_insp_bg_color(color: Color) -> void:
	if _loading_inspector:
		return
	_background = "#" + color.to_html(true)
	_stage_view.set_background(color)


## Load the grid controls (show / snap / colour / step) from the project's `_grid_settings` and apply
## them to the stage view (M27). The mirror of _sync_background — run on every project load, since the
## grid is now a project property. Guarded by _loading_inspector so setting a control can't echo back
## through its _on_grid_* handler and dirty the project during a load.
func _sync_grid() -> void:
	_loading_inspector = true
	_grid_show.button_pressed = bool(_grid_settings.get("show", true))
	_grid_snap.button_pressed = bool(_grid_settings.get("snap", true))
	_grid_color.color = Color(String(_grid_settings.get("color", "#87cefa59")))
	_grid_step.value = float(_grid_settings.get("step", 8))
	_loading_inspector = false
	_stage_view.set_grid_show(_grid_show.button_pressed)
	_stage_view.set_grid_snap(_grid_snap.button_pressed)
	_stage_view.set_grid_color(_grid_color.color)
	_stage_view.set_grid_step(int(_grid_step.value))


## The grid inspector handlers (M27): each writes its value into the `_grid_settings` project property
## and applies it to the stage view, so the change rides _write_project on SAVE. Skipped while
## _sync_grid is loading the controls (so a read can't echo back). The step spinner reports a float, so
## it casts to the int model px the grid/snap use.
func _on_grid_show(shown: bool) -> void:
	if _loading_inspector:
		return
	_grid_settings["show"] = shown
	_stage_view.set_grid_show(shown)


func _on_grid_snap(snap: bool) -> void:
	if _loading_inspector:
		return
	_grid_settings["snap"] = snap
	_stage_view.set_grid_snap(snap)


func _on_grid_color(color: Color) -> void:
	if _loading_inspector:
		return
	_grid_settings["color"] = "#" + color.to_html(true)
	_stage_view.set_grid_color(color)


func _on_grid_step_changed(value: float) -> void:
	if _loading_inspector:
		return
	_grid_settings["step"] = int(value)
	_stage_view.set_grid_step(int(value))


## The project's sprite names (M17), the sprites half of the project model — the targets a
## `touching {name}?` slot offers. Derived straight from the script list, the editor's existing
## name registry, so it stays in step with whatever sprites the project has.
func _sprite_names() -> Array:
	var names: Array = []
	for entry in _scripts:
		names.append(entry["name"])
	return names


# --- Add / delete a sprite (M24) -------------------------------------------

## Pop the Add-Sprite name prompt (the top-bar button's callback). The dialog is declared in
## editor.tscn and reused; Enter-to-confirm is wired in _ready.
func _add_sprite_pressed() -> void:
	_sprite_name_edit.text = ""
	_sprite_dialog.popup_centered(Vector2i(280, 130))
	_sprite_name_edit.grab_focus()


## Mint a sprite: append a fresh entry — the typed name + default placeholder geometry + an empty
## script (Scratch's new sprite has no scripts) — to the working model, then bring it up in the UI
## selected. A blank or duplicate name is rejected silently (names are the project's target registry,
## so they must stay unique). It starts at the stage center as a grey square; you script it from there
## (a `go_to` block repositions it, as the ball does), and it is seeded/run at RUN like any sprite.
func _on_new_sprite_confirmed() -> void:
	var sprite_name := _sprite_name_edit.text.strip_edges()
	if sprite_name == "" or sprite_name in _sprite_names():
		return
	_persist_current()  # keep the outgoing canvas's edits before the selector reloads
	var entry := _DEFAULT_SPRITE.duplicate()
	entry["name"] = sprite_name
	entry["script"] = []
	_scripts.append(entry)
	_load_project_into_ui(_scripts.size() - 1)


## Pop the delete-confirmation dialog for the selected sprite, reporting how many of its locals go with
## it and how many `touching` references to it will be cleared (M25). Refused when only one sprite is
## left (the project always has at least one target). We persist the canvas first so a switch away can't
## lose edits, and stash the name the confirm acts on.
func _del_sprite_pressed() -> void:
	if _scripts.size() <= 1:
		return
	_persist_current()
	var sprite_name := String(_scripts[_current]["name"])
	_deleting_sprite = sprite_name
	var locals := 0
	for v in _variables:
		if String(v.get("scope", "global")) == sprite_name:
			locals += 1
	# Count the dangling `touching {name}?` references the delete will clear in the *surviving* scripts
	# (the deleted sprite's own script goes wholesale, so its self-references aren't "cleared", just
	# gone). M24 left these dangling (they resolved null/false at RUN); M25 strips them, so the dialog
	# warns up front.
	var refs := 0
	for i in _scripts.size():
		if i != _current:
			refs += BlockView.count_sprite_refs(_scripts[i]["script"], sprite_name)
	var msg := "Delete sprite \"%s\"? Its script" % sprite_name
	if locals > 0:
		msg += " and %d local variable(s)" % locals
	msg += " will be removed."
	if refs > 0:
		msg += "\n%d \"touching\" reference(s) to it will be cleared." % refs
	_del_sprite_label.text = msg
	_del_sprite_dialog.popup_centered(Vector2i(380, 150))


## Commit a sprite delete: drop the sprite's model entry and every variable scoped to it (its locals),
## strip every dangling `touching {name}?` reference to it across the surviving scripts (M25 — the
## sprite analog of M21's variable-delete strip; M24 left these dangling, resolving null/false at RUN),
## then reload the UI on a surviving neighbour. A stripped `touching {name}?` reporter reverts its slot
## to the host opcode's default (so `if (touching Gone?)` becomes `if true`); no dangling name remains
## (Scratch's behaviour). Destructive; there is no undo (relaunch reloads stock).
func _on_del_sprite_confirmed() -> void:
	var index := -1
	for i in _scripts.size():
		if String(_scripts[i]["name"]) == _deleting_sprite:
			index = i
			break
	if index < 0:
		return
	_scripts.remove_at(index)
	for i in range(_variables.size() - 1, -1, -1):
		if String(_variables[i].get("scope", "global")) == _deleting_sprite:
			_variables.remove_at(i)
	# Clear the references the gone sprite leaves behind in every remaining script (M25). We strip
	# directly on each `_scripts` entry rather than in place on the canvas because the delete always
	# navigates to a surviving neighbour, whose canvas _load_project_into_ui reloads from scratch anyway.
	for entry in _scripts:
		BlockView.strip_sprite_refs(entry["script"], _deleting_sprite)
	# _load_project_into_ui resets _current to -1 before showing, so its leading _persist_current can't
	# write the just-removed sprite's stale canvas back. `index` is clamped to the new (smaller) bounds,
	# landing on the sprite that shifted into this slot, or the new last one if we deleted the tail.
	_load_project_into_ui(index)


## Pop the rename dialog for the selected sprite (M25), pre-filled with its current name (selected, so
## the user can type a replacement immediately). The button always targets the selected sprite, so the
## name we stash is `_current`'s — the sprite analog of the variable rename's `_renaming`.
func _rename_sprite_pressed() -> void:
	var sprite_name := String(_scripts[_current]["name"])
	_renaming_sprite = sprite_name
	_rename_sprite_edit.text = sprite_name
	_rename_sprite_dialog.popup_centered(Vector2i(280, 130))
	_rename_sprite_edit.grab_focus()
	_rename_sprite_edit.select_all()


## Commit a sprite rename (M25 — the sprite analog of M21's variable rename). Update the model entry's
## name, re-scope every variable local to the sprite (a local is scoped by its sprite's name, so it must
## follow the rename), then cascade the new name into every script's `touching {name}?` references. A
## sprite name is globally unique, so the cascade is unscoped — every script may reference it (any sprite
## can touch any other), unlike a variable's per-scope referent test. The current sprite is rewritten in
## place via the canvas (preserving its layout, the M21 reasoning); the others via
## BlockView.rewrite_sprite_refs on `_scripts[i]`. Then the chrome + data-scoped menus pick up the new
## name in place (the selector item, project_sprites, the re-scoped project_variables, the palette, the
## canvas) — no full reload, so canvas positions survive. Blank / unchanged / duplicate names are rejected
## silently (names are the project's target registry, so they must stay unique).
func _on_rename_sprite_confirmed() -> void:
	var new_name := _rename_sprite_edit.text.strip_edges()
	var old_name := _renaming_sprite
	if new_name == "" or new_name == old_name or new_name in _sprite_names():
		return
	# The button targets the selected sprite, so the stashed name is _current's; bail if they've
	# diverged (defensive — the dialog is modal, so this shouldn't happen).
	if _current < 0 or _current >= _scripts.size() or String(_scripts[_current]["name"]) != old_name:
		return

	_persist_current()  # sync the canvas into _scripts[_current] before the cascade
	_scripts[_current]["name"] = new_name
	# A sprite's locals are scoped by its name (PongScripts.variables / Make a Variable), so the rename
	# carries them along — else they'd dangle, scoped to a sprite that no longer exists.
	for v in _variables:
		if String(v.get("scope", "global")) == old_name:
			v["scope"] = new_name
	# Cascade `touching {name}?` references across every script.
	for i in _scripts.size():
		if i == _current:
			_canvas.rename_sprite(old_name, new_name)  # in place — preserves canvas positions
		else:
			BlockView.rewrite_sprite_refs(_scripts[i]["script"], old_name, new_name)

	# Reflect the new name in the chrome and the data-scoped menus, in place (no reload, so positions
	# hold): the selector item, the `touching` dropdown options, the re-scoped variable list (the
	# renamed sprite's locals are still in scope under its new name), the palette, and the canvas.
	_selector.set_item_text(_current, new_name)
	BlockView.project_sprites = _sprite_names()
	BlockView.project_variables = _variables_in_scope(new_name)
	_palette.rebuild()
	_canvas.refresh()  # after re-pointing project_sprites, so the new name is an in-scope option
	if _stage_mode:
		_sync_inspector()  # the inspector's "Sprite: <name>" label tracks the rename


## Fill any missing placeholder geometry on a sprite entry with the defaults (M24) — used to upgrade a
## project saved before M24 (entries with only name/script) so the Stage can build it.
func _normalize_sprite(entry: Dictionary) -> void:
	for key in _DEFAULT_SPRITE:
		if not entry.has(key):
			entry[key] = _DEFAULT_SPRITE[key]


## The variable names in scope for `sprite_name` (M19) — the options its `{name}` slots offer.
## A variable is in scope when it is a **global** or a **local of this very sprite**; another
## sprite's locals are hidden, mirroring Scratch (a sprite can't see a sibling's local). Reads
## the editor-owned model `_variables` (M20) — seeded from PongScripts.variables() (the same
## declaration the Stage seeds from) and extended by "Make a Variable", each entry carrying the
## `scope` this reads ("global" or a sprite name). Re-evaluated per sprite by _show.
##
## (Before M19 this took no argument and listed *every* variable for every sprite — flat, the
## deferral M18's scope-in-the-data was the prerequisite for. The Ball's `speed` now shows only
## while editing the Ball.)
func _variables_in_scope(sprite_name: String) -> Array:
	var names: Array = []
	for v in _variables:
		var scope := String(v.get("scope", "global"))
		if scope == "global" or scope == sprite_name:
			names.append(v["name"])
	return names


# --- Make a Variable (M20) -------------------------------------------------

## Pop the dialog with a blank, all-sprites default — the palette button's callback.
## The dialog (name field + global/local scope selector) is declared in editor.tscn; its
## scope items are fixed text, so they live in the scene, and Enter-to-confirm is wired in _ready.
func _make_variable() -> void:
	_var_name_edit.text = ""
	_var_scope.select(0)
	_var_dialog.popup_centered(Vector2i(280, 150))
	_var_name_edit.grab_focus()


## Mint the variable: append a fresh {name, value: 0, scope} entry to the owned model (Scratch
## starts a new variable at 0), then re-scope the dropdowns and refresh the palette + canvas so
## it shows immediately. Scope is "global" (all sprites) or the edited sprite's name (local).
## A blank name, or one already in scope for this sprite, is rejected silently — the in-scope
## check forbids shadowing a name the sprite can already see (a sibling's local, which it can't
## see, is fine to reuse, matching Scratch).
func _on_new_variable_confirmed() -> void:
	var var_name := _var_name_edit.text.strip_edges()
	if var_name == "":
		return
	var sprite_name := String(_scripts[_current]["name"])
	if var_name in _variables_in_scope(sprite_name):
		return
	var scope := "global" if _var_scope.selected == 0 else sprite_name
	_variables.append({"name": var_name, "value": 0, "scope": scope})

	# The new name must reach the dropdowns the same way M19's scoping does: re-point the scoped
	# list, rebuild the palette's variable chips, and re-render the canvas so any open `{name}`
	# dropdown lists it too.
	BlockView.project_variables = _variables_in_scope(sprite_name)
	_palette.rebuild()
	_canvas.refresh()


# --- Make a Block / custom blocks (M30) ------------------------------------

## The custom-block (My Blocks) names a script defines — the `name` of every top-level `define`
## hat. Custom blocks live in the data (the `define` hats), not a separate model, so this derives
## them on demand the way _sprite_names derives sprite names from _scripts. A `call {name}` slot
## lists these (data_enums "custom_blocks" → BlockView.project_custom_blocks). `define`s are always
## stack roots, so scanning the top level suffices.
func _custom_blocks_in(script: Array) -> Array:
	var names: Array = []
	for block in script:
		if typeof(block) == TYPE_DICTIONARY and String(block.get("opcode", "")) == "define":
			var n := String(block.get("inputs", {}).get("name", ""))
			if n != "" and n not in names:
				names.append(n)
	return names


## Pop the Make a Block name prompt (the palette button's callback). The dialog is declared in
## editor.tscn and reused; Enter-to-confirm is wired in _ready.
func _make_block() -> void:
	_block_name_edit.text = ""
	_block_dialog.popup_centered(Vector2i(280, 130))
	_block_name_edit.grab_focus()


## Mint a custom block: add a `define {name}` hat to the canvas (so the new procedure appears
## immediately and rides export_script() → persistence/RUN like any block), then re-derive this
## sprite's custom blocks from the live canvas and rebuild the palette + canvas so the new name
## shows up as a `call` chip and in every `call {name}` dropdown. A blank or already-defined name
## is rejected silently (a sprite's custom-block names must stay unique — `call` resolves by name).
func _on_new_block_confirmed() -> void:
	var block_name := _block_name_edit.text.strip_edges()
	if block_name == "" or block_name in _custom_blocks_in(_canvas.export_script()):
		return
	var define := BlockView.make_block("define")
	define["inputs"]["name"] = block_name
	_canvas.add_definition(define)
	# Re-derive from the live canvas (the new define isn't in _scripts until the next persist), then
	# refresh the dependent UI — the same trio Make a Variable uses to surface a new name.
	BlockView.project_custom_blocks = _custom_blocks_in(_canvas.export_script())
	_palette.rebuild()
	_canvas.refresh()


# --- Rename / delete a variable (M21) --------------------------------------

## Pop the rename dialog for `name` (a palette row's menu callback). The name is selected so the
## user can type a replacement immediately.
func _rename_variable(var_name: String) -> void:
	_renaming = var_name
	_rename_edit.text = var_name
	_rename_dialog.popup_centered(Vector2i(280, 130))
	_rename_edit.grab_focus()
	_rename_edit.select_all()


## Commit a rename: update the model entry's name, then cascade the new name into every script
## where this variable is the in-scope referent (the current sprite in place via the canvas, the
## rest via BlockView.rewrite_variable_refs), and re-scope/rebuild/refresh the UI (the M20 trio).
## A blank name, no-op (unchanged), or a name already in scope for this sprite is rejected silently
## — the in-scope guard mirrors "Make a Variable" (it forbids colliding with a name the sprite can
## already see; a sibling's local, which it can't see, is irrelevant).
func _on_rename_confirmed() -> void:
	var new_name := _rename_edit.text.strip_edges()
	if new_name == "" or new_name == _renaming:
		return
	var sprite_name := String(_scripts[_current]["name"])
	if new_name in _variables_in_scope(sprite_name):
		return
	var entry := _in_scope_entry(_renaming)
	if entry.is_empty():
		return
	var scope := String(entry.get("scope", "global"))
	var old_name := _renaming

	_persist_current()  # sync the canvas into _scripts[_current] before the cascade
	entry["name"] = new_name
	for i in _scripts.size():
		if not _is_referent_for(String(_scripts[i]["name"]), old_name, scope):
			continue
		if i == _current:
			_canvas.rename_variable(old_name, new_name)  # in place — preserves canvas positions
		else:
			BlockView.rewrite_variable_refs(_scripts[i]["script"], old_name, new_name)

	BlockView.project_variables = _variables_in_scope(sprite_name)
	_palette.rebuild()
	_canvas.refresh()  # after re-pointing project_variables, so the new name is an in-scope option


## Pop the delete-confirmation dialog for `var_name`, reporting how many references it has (counted
## over the in-scope scripts). We persist the canvas first so the current sprite's count reads from
## up-to-date data. Confirming strips those references (see _on_delete_confirmed), so the dialog warns.
func _delete_variable(var_name: String) -> void:
	_persist_current()
	_deleting = var_name
	var entry := _in_scope_entry(var_name)
	if entry.is_empty():
		return
	var scope := String(entry.get("scope", "global"))
	var uses := 0
	for i in _scripts.size():
		if _is_referent_for(String(_scripts[i]["name"]), var_name, scope):
			uses += BlockView.count_variable_refs(_scripts[i]["script"], var_name)
	_delete_label.text = "Delete \"%s\"?\n%d reference(s) in the scripts will be removed too." % [var_name, uses]
	_delete_dialog.popup_centered(Vector2i(380, 140))


## Commit a delete: strip every reference, then remove the model entry. References are removed where
## this variable is the in-scope referent (same scoping as rename, _is_referent_for): the current
## sprite in place via BlockCanvas.delete_variable_refs (positions preserved), the rest via
## BlockView.strip_variable_refs on _scripts[i]. set_var/change_var statements are dropped and
## `variable` reporters revert their slot to a default — no dangling name survives (Scratch's
## behavior). Delete is destructive; there is no undo (relaunch reloads the stock set).
func _on_delete_confirmed() -> void:
	var entry := _in_scope_entry(_deleting)
	if entry.is_empty():
		return
	var scope := String(entry.get("scope", "global"))
	var sprite_name := String(_scripts[_current]["name"])

	for i in _scripts.size():
		if not _is_referent_for(String(_scripts[i]["name"]), _deleting, scope):
			continue
		if i == _current:
			_canvas.delete_variable_refs(_deleting)  # in place — preserves canvas positions
		else:
			BlockView.strip_variable_refs(_scripts[i]["script"], _deleting)

	for i in _variables.size():
		var v: Dictionary = _variables[i]
		var s := String(v.get("scope", "global"))
		if String(v["name"]) == _deleting and (s == "global" or s == sprite_name):
			_variables.remove_at(i)
			break

	BlockView.project_variables = _variables_in_scope(sprite_name)
	_palette.rebuild()
	_canvas.refresh()


## The model entry for `var_name` that the current sprite sees (a global, or a local of this
## sprite), or {} if none. A name is unique within a sprite's scope (the make/rename guards forbid
## an in-scope collision), so this resolves to exactly the entry a palette row stands for.
func _in_scope_entry(var_name: String) -> Dictionary:
	var sprite_name := String(_scripts[_current]["name"])
	for v in _variables:
		var scope := String(v.get("scope", "global"))
		if String(v["name"]) == var_name and (scope == "global" or scope == sprite_name):
			return v
	return {}


## Whether `var_name` (a variable of scope `scope`) is the referent `sprite_name`'s script sees
## under that name — the test the rename/delete cascade scopes on. A local is the referent only for
## its own sprite; a global is the referent everywhere *except* a sprite that shadows it with its
## own local of the same name (there, the name means the local, so the global's cascade skips it).
func _is_referent_for(sprite_name: String, var_name: String, scope: String) -> bool:
	if scope == "global":
		return not _sprite_has_local(sprite_name, var_name)
	return sprite_name == scope


## Whether `sprite_name` declares a local variable named `var_name`.
func _sprite_has_local(sprite_name: String, var_name: String) -> bool:
	for v in _variables:
		if String(v["name"]) == var_name and String(v.get("scope", "global")) == sprite_name:
			return true
	return false


## Serialize the canvas's current edits back into the selected sprite's entry, so they
## survive a sprite switch or a RUN. A no-op before the first load (_current == -1).
func _persist_current() -> void:
	if _current >= 0 and _current < _scripts.size():
		_scripts[_current]["script"] = _canvas.export_script()


# --- Save / open named projects (M22) --------------------------------------

## Reset the working project to the stock demo, without touching any saved file (M22). The demo is
## always reachable this way and your saved `.json` projects are left untouched; it is unsaved (no
## bound path) until you SAVE it under a name. Discards the current canvas's unsaved edits — like
## the rest of the app there is no undo (M16), so SAVE first if you want to keep them.
func _on_new() -> void:
	_seed_demo()
	_current_path = ""
	_load_project_into_ui()


## Pop the file browser to SAVE the project wherever the user chooses (M22). Persist the canvas first
## so the file captures the latest edits, then open the browser pre-filled with the bound path (so
## re-saving is SAVE → confirm) or, for a never-saved project, at the project-dir default. The actual
## write happens in _on_file_selected once the user picks a name and location.
func _on_save() -> void:
	_persist_current()
	_file_action = "save"
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.title = "Save Project"
	if _current_path != "":
		_file_dialog.current_path = _current_path
	else:
		_file_dialog.current_dir = _default_browse_dir()
	_file_dialog.popup_centered()


## Pop the file browser to OPEN a saved project from wherever the user put it (M22). Opens at the
## bound file's folder if one is set, else the project-dir default. The load happens in
## _on_file_selected; it replaces the working project (discarding unsaved canvas edits, as NEW does).
func _on_open() -> void:
	_file_action = "open"
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.title = "Open Project"
	_file_dialog.current_dir = _current_path.get_base_dir() if _current_path != "" else _default_browse_dir()
	_file_dialog.popup_centered()


## The FileDialog's pick: route to write or read by the action recorded when it was popped (one
## dialog serves both, the rename/delete "state var carries the payload" idiom).
func _on_file_selected(path: String) -> void:
	if _file_action == "save":
		_write_project(path)
	elif _file_action == "open":
		_read_project(path)


## Serialize the project — {scripts, variables} — as JSON to `path` (M22). The block model is
## already plain dicts / arrays / primitives ("exactly the shape a visual editor would emit"), so
## this is a near-direct JSON.stringify (tab-indented for a human-readable file). Binds the project
## to this file so the title shows its name and a later SAVE overwrites it.
func _write_project(path: String) -> void:
	var data := {"scripts": _scripts, "variables": _variables, "background": _background, "grid": _grid_settings}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Editor: could not write project to '%s'" % path)
		return
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	_current_path = path
	_update_title()


## Load a saved project from `path` (M22), replacing the working project. Unreadable or malformed
## input is ignored (push_warning, keep the current project) so a hand-edited or corrupt file can't
## crash the editor. Note JSON parses every number as a float (`10` → `10.0`); this is harmless —
## the interpreter float()s numerics, BlockView._stringify trims a whole float's `.0`, and the
## slot-shape typing treats int/float identically — the same round-trip RUN's deep-copy never had to
## worry about, surfacing here only because JSON has one number type.
func _read_project(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Editor: could not read project from '%s'" % path)
		return
	var text := file.get_as_text()
	file.close()
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("scripts")) != TYPE_ARRAY \
			or typeof(data.get("variables")) != TYPE_ARRAY:
		push_warning("Editor: '%s' is not a valid project file" % path)
		return
	_scripts = data["scripts"]
	# Fill any missing geometry (M24): a project saved before M24 has entries with only name/script,
	# so default their placeholder geometry rather than crash when the Stage builds them. New saves
	# carry x/y/w/h/color; this only matters for older files.
	for entry in _scripts:
		_normalize_sprite(entry)
	_variables = data["variables"]
	# Background is a top-level project property (M27); default it for a project saved before M27 (or
	# any file without the key) so an older save still opens.
	_background = String(data.get("background", PongScripts.background()))
	# Grid settings are likewise a top-level project property (M27). Start from the stock defaults and
	# overlay whatever the file carried, so a save written before the grid was persisted — or one
	# missing individual keys — still opens with sane values rather than a partial dict.
	_grid_settings = PongScripts.grid()
	var saved_grid: Variant = data.get("grid")
	if typeof(saved_grid) == TYPE_DICTIONARY:
		for key in saved_grid:
			_grid_settings[key] = saved_grid[key]
	_current_path = path
	_load_project_into_ui()


## Reflect the bound project in the title bar (M22): the file's stem for a saved project, or a
## "(demo)" marker for the unsaved in-code demo, so it is clear what SAVE will overwrite.
func _update_title() -> void:
	if _current_path == "":
		_title.text = "scratch-like — (demo)"
	else:
		_title.text = "scratch-like — %s" % _current_path.get_file().get_basename()


## RUN: hand the *edited* project to the Stage and switch to the game scene (M10). The
## scripts ride across the scene change on a static var (a plain value can't be passed
## through change_scene_to_file); the Stage reads it, falling back to PongScripts for
## any sprite it lacks — so launching main.tscn directly still plays stock Pong. We
## deep-duplicate so the running game can't mutate the editor's working data.
func _on_run() -> void:
	_persist_current()
	# Hand the whole sprite model over (M24): each entry's geometry *and* script, including any
	# sprites added in the UI. This replaces M10's separate name->script Dictionary now that the
	# script rides inside each sprite entry (Stage builds from project_sprites). Deep-duplicated, so
	# the running game can't mutate the editor's working copy.
	Stage.project_sprites = _scripts.duplicate(true)
	# Hand over the variable model too (M20), so a variable made in the editor is seeded at RUN.
	Stage.project_variables = _variables.duplicate(true)
	# Hand over the stage background (M27), so the game paints the colour the editor showed.
	Stage.project_background = _background
	get_tree().change_scene_to_file(_GAME_SCENE)
