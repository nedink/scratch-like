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

## A freshly added sprite's placeholder geometry (M24): a small grey square at the stage center. It is
## just a starting placeholder — real positioning is blocks (a `go_to` in the sprite's script, as the
## ball does), so there is no UI yet to move/resize/recolour it (deferred to M25). Also the fill values
## _read_project defaults a pre-M24 saved entry to.
const _DEFAULT_SPRITE := {"x": 240, "y": 180, "w": 24, "h": 24, "color": "#cccccc"}


func _ready() -> void:
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
	_canvas._trash = _palette_scroll

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

	# Populate the selector + canvas from the seeded project and show its first sprite.
	_load_project_into_ui()


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
	var index: int = clampi(select_index, 0, _scripts.size() - 1)
	_selector.select(index)
	_show(index)


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
## it. Refused when only one sprite is left (the project always has at least one target). We persist the
## canvas first so a switch away can't lose edits, and stash the name the confirm acts on.
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
	_del_sprite_label.text = "Delete sprite \"%s\"?\nIts script%s removed." % \
		[sprite_name, (" and %d local variable(s) will be" % locals) if locals > 0 else " will be"]
	_del_sprite_dialog.popup_centered(Vector2i(380, 140))


## Commit a sprite delete: drop the sprite's model entry and every variable scoped to it (its locals),
## then reload the UI on a surviving neighbour. References to the gone sprite in *other* scripts (a
## `touching {name}?` slot) are left as-is — find_target returns null so the reporter is simply false at
## RUN (no crash), and the dropdown keeps the name visible (M13's append-the-unknown). Stripping those
## is the sprite-rename cascade, deferred to M25. Destructive; there is no undo (relaunch reloads stock).
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
	# _load_project_into_ui resets _current to -1 before showing, so its leading _persist_current can't
	# write the just-removed sprite's stale canvas back. `index` is clamped to the new (smaller) bounds,
	# landing on the sprite that shifted into this slot, or the new last one if we deleted the tail.
	_load_project_into_ui(index)


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
	var data := {"scripts": _scripts, "variables": _variables}
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
	get_tree().change_scene_to_file(_GAME_SCENE)
