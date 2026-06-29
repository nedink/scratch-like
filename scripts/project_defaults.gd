class_name ProjectDefaults
extends RefCounted

## The stage-level defaults a **blank** project starts from — the project background colour and the
## stage-editor grid settings. The editor seeds its working copy from here (a NEW project), falls back
## to these when opening a saved file that predates either setting, and the Stage falls back to the
## background when launched directly (no editor).
##
## A blank project has **no sprites, variables, or lists** — those models simply start empty (the
## editor seeds `_scripts` / `_variables` / `_lists` to `[]`), so there's nothing to declare here. The
## in-code Pong demo that lived in this file through earlier milestones has been removed: the project
## now opens on a blank stage, and any demo worth keeping lives as a saved `.json` project instead.


## The project's stage background colour as a **hex string** (so it serialises straight to JSON for
## SAVE/OPEN — the editor stores it under a top-level "background" key). The stock value is opaque black.
static func background() -> String:
	return "#000000ff"


## The stage-editor alignment grid settings (visibility, snap, colour, spacing). A stage-level project
## property — seeded into the editor's working copy, saved under a top-level "grid" key, reloaded on
## OPEN. `color` is a hex string with alpha (the JSON-clean format); `step` is in model pixels. The
## stock values match the stage view's standalone defaults (a faint sky-blue 8px grid, show + snap on).
static func grid() -> Dictionary:
	return {
		"show": true,
		"snap": true,
		"color": "#" + Color(0.529, 0.808, 0.980, 0.35).to_html(true),
		"step": 8,
	}
