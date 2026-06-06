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
## Like stage.gd, the UI is built entirely in code; editor.tscn is a bare root
## Control + this script, matching the project's "generate the scene tree in code"
## idiom (main.tscn is likewise a bare Node2D + stage.gd).

## The game scene the RUN button launches. main.tscn is unchanged from M7 — it is
## just no longer the project's main_scene (the editor is); it is the *game* now.
const _GAME_SCENE := "res://main.tscn"

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
var _canvas: BlockCanvas

## The block palette (M11): the source of *new* blocks. Hands fresh blocks to the canvas.
var _palette: BlockPalette

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
## Built once in _ready and reused; the palette button pops it via _make_variable.
var _var_dialog: ConfirmationDialog
var _var_name_edit: LineEdit
var _var_scope: OptionButton

## The rename / delete dialogs (M21), built once in _ready and reused. A palette variable row's
## menu pops one of these via _rename_variable / _delete_variable; _renaming / _deleting hold the
## name the open dialog is acting on (the dialogs' confirmed signals carry no payload). The delete
## label is rewritten per-invocation to report the usage count.
var _rename_dialog: ConfirmationDialog
var _rename_edit: LineEdit
var _renaming: String = ""
var _delete_dialog: ConfirmationDialog
var _delete_label: Label
var _deleting: String = ""


func _ready() -> void:
	_scripts = [
		{"name": "LeftPaddle", "script": PongScripts.left_paddle()},
		{"name": "RightPaddle", "script": PongScripts.right_paddle()},
		{"name": "Ball", "script": PongScripts.ball()},
		{"name": "P1Hud", "script": PongScripts.p1_hud()},
		{"name": "P2Hud", "script": PongScripts.p2_hud()},
		{"name": "Announcer", "script": PongScripts.announcer()},
	]

	# The editor's own mutable copy of the variable model (M20), seeded from the one runtime
	# declaration. "Make a Variable" appends to *this* (PongScripts.variables() returns a fresh
	# array each call, so it was no store to add to); _on_run hands it back to the Stage.
	_variables = PongScripts.variables().duplicate(true)

	# Hand the project model to the renderer (M17) *before* the palette builds and the canvas
	# renders, so the `{name}` slots of variable/set/change and touching {name}? draw as
	# data-scoped dropdowns. Sprite names come straight from the script list above; variable
	# names from the one project model the runtime seeds from too (M18 — PongScripts.variables(),
	# no longer a separate hardcoded list here). (Static on BlockView, like Stage.project_scripts.)
	#
	# The variable list is **scoped to the sprite being edited** (M19): globals plus that
	# sprite's own locals, hiding other sprites' locals — so editing the LeftPaddle never
	# offers the Ball's `speed`. Seed it for the first sprite the selector will show (index 0);
	# _show re-scopes it on every switch. Sprites aren't scoped (all are valid `touching` targets).
	BlockView.project_sprites = _sprite_names()
	BlockView.project_variables = _variables_in_scope(_scripts[0]["name"])

	# A small default font size so the chunky blocks fit the 480x360 viewport (which
	# the project integer-stretches to fullscreen). One Theme on the root cascades to
	# every label and button below.
	var ui_theme := Theme.new()
	ui_theme.default_font_size = 11
	theme = ui_theme
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Dark backdrop behind everything (added first so it sits at the back).
	var backdrop := ColorRect.new()
	backdrop.color = Color("#1e1e22")
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var page := VBoxContainer.new()
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_theme_constant_override("separation", 4)
	add_child(page)

	# Top bar: title + sprite selector + RUN.
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)

	var title := Label.new()
	title.text = "scratch-like"
	bar.add_child(title)

	var selector := OptionButton.new()
	for entry in _scripts:
		selector.add_item(entry["name"])
	selector.item_selected.connect(_on_select)
	bar.add_child(selector)

	# Push RUN to the right edge.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	var run := Button.new()
	run.text = "RUN"
	run.pressed.connect(_on_run)
	bar.add_child(run)

	# The workspace: a fixed-width palette of new blocks (M11) on the left, the editable
	# canvas filling the rest. Each sits in its own ScrollContainer (the palette's list
	# and a tall script both overflow). Hit-testing uses global coordinates throughout,
	# so both stay correct whatever their scroll offsets.
	var workspace := HBoxContainer.new()
	workspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workspace.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_theme_constant_override("separation", 4)
	page.add_child(workspace)

	# Fixed-width viewport; the palette scrolls vertically through the block list and, if
	# a long block label overflows the width, horizontally too (rather than clipping it).
	var palette_scroll := ScrollContainer.new()
	palette_scroll.custom_minimum_size = Vector2(150, 0)
	palette_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(palette_scroll)

	_palette = BlockPalette.new()
	palette_scroll.add_child(_palette)

	# The canvas gets a generous minimum size so there's room to drag stacks around and
	# scrollbars appear when content overflows.
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workspace.add_child(scroll)

	_canvas = BlockCanvas.new()
	_canvas.custom_minimum_size = Vector2(1200, 1200)
	scroll.add_child(_canvas)

	# The palette feeds fresh blocks to the canvas (M11) and doubles as the canvas's trash:
	# dragging a block back over the palette region deletes it (M16, Scratch's own gesture).
	# Its "Make a Variable" button (M20) calls back here to mint a new variable.
	_palette._canvas = _canvas
	_palette._on_make_variable = _make_variable
	# Each in-scope variable's palette row (M21) calls back here to rename or delete it.
	_palette._on_rename_variable = _rename_variable
	_palette._on_delete_variable = _delete_variable
	_canvas._trash = palette_scroll

	_build_variable_dialog()
	_build_rename_dialog()
	_build_delete_dialog()
	_show(0)


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
	_palette.rebuild()
	_canvas.load_script(_scripts[index]["script"])


func _on_select(index: int) -> void:
	_show(index)


## The project's sprite names (M17), the sprites half of the project model — the targets a
## `touching {name}?` slot offers. Derived straight from the script list, the editor's existing
## name registry, so it stays in step with whatever sprites the project has.
func _sprite_names() -> Array:
	var names: Array = []
	for entry in _scripts:
		names.append(entry["name"])
	return names


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

## Build the "Make a Variable" dialog once: a name field and a global/local scope selector.
## Reused on every press of the palette button (popped by _make_variable). Enter in the name
## field confirms (register_text_enter), matching Scratch's quick flow.
func _build_variable_dialog() -> void:
	_var_dialog = ConfirmationDialog.new()
	_var_dialog.title = "New Variable"
	_var_dialog.confirmed.connect(_on_new_variable_confirmed)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var name_label := Label.new()
	name_label.text = "Variable name:"
	box.add_child(name_label)

	_var_name_edit = LineEdit.new()
	_var_name_edit.custom_minimum_size = Vector2(220, 0)
	box.add_child(_var_name_edit)

	_var_scope = OptionButton.new()
	_var_scope.add_item("For all sprites")        # index 0 -> "global"
	_var_scope.add_item("For this sprite only")   # index 1 -> the edited sprite's name
	box.add_child(_var_scope)

	_var_dialog.add_child(box)
	add_child(_var_dialog)
	_var_dialog.register_text_enter(_var_name_edit)


## Pop the dialog with a blank, all-sprites default — the palette button's callback.
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


# --- Rename / delete a variable (M21) --------------------------------------

## Build the rename dialog once: a single name field, prefilled with the current name when popped.
## Enter confirms (register_text_enter), like the make dialog.
func _build_rename_dialog() -> void:
	_rename_dialog = ConfirmationDialog.new()
	_rename_dialog.title = "Rename Variable"
	_rename_dialog.confirmed.connect(_on_rename_confirmed)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = "New name:"
	box.add_child(label)
	_rename_edit = LineEdit.new()
	_rename_edit.custom_minimum_size = Vector2(220, 0)
	box.add_child(_rename_edit)

	_rename_dialog.add_child(box)
	add_child(_rename_dialog)
	_rename_dialog.register_text_enter(_rename_edit)


## Build the delete-confirmation dialog once. Its label is rewritten each time it pops to name the
## variable and report how many blocks use it (and that they survive the delete).
func _build_delete_dialog() -> void:
	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete Variable"
	_delete_dialog.confirmed.connect(_on_delete_confirmed)
	_delete_label = Label.new()
	_delete_dialog.add_child(_delete_label)
	add_child(_delete_dialog)


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


## RUN: hand the *edited* project to the Stage and switch to the game scene (M10). The
## scripts ride across the scene change on a static var (a plain value can't be passed
## through change_scene_to_file); the Stage reads it, falling back to PongScripts for
## any sprite it lacks — so launching main.tscn directly still plays stock Pong. We
## deep-duplicate so the running game can't mutate the editor's working data.
func _on_run() -> void:
	_persist_current()
	var project: Dictionary = {}
	for entry in _scripts:
		project[entry["name"]] = (entry["script"] as Array).duplicate(true)
	Stage.project_scripts = project
	# Hand over the variable model too (M20), so a variable made in the editor is seeded at RUN.
	# Deep-duplicated like the scripts, so the running game can't mutate the editor's working copy.
	Stage.project_variables = _variables.duplicate(true)
	get_tree().change_scene_to_file(_GAME_SCENE)
