# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Last shipped:** M40 — **multiple-stage functionality removed** (reverted to a single flat project).
  M33/M34 added a project-level *scene (stage / level)* layer — a `_scenes` list + active index in the
  editor, a top-bar scene selector + Add/Delete/Rename Scene chrome, `switch_scene`/`next_scene` blocks,
  the Stage carrying the whole scene list (`project_scenes`/`project_active`), and a `{scenes, active}`
  save shape. M40 rips all of that out: the editor again owns flat `_scripts`/`_variables`/`_background`/
  `_grid_settings` directly (the seeds come straight from `PongScripts.sprites()/variables()/background()/
  grid()` — `scenes()` is gone), the Stage takes the three per-scene statics again
  (`project_sprites`/`project_variables`/`project_background` + `_sprite_model`/`_variable_model`/
  `_background_hex` fallbacks), the two scene-nav opcodes + their interpreter handlers + the `scenes`
  category + `project_scene_names` are deleted, and persistence is back to flat
  `{scripts, variables, background, grid}`. RUN/ESC still use `change_scene_to_file` (that's the Godot
  scene swap, not the removed project-scene layer). Rationale: multi-stage complicated persistence and
  cross-stage state we're not ready to tackle, and the chrome ate top-bar space — we only need one stage
  now. **No backward-compat in the loader** (a deliberate scope call — see next action).
- **Git:** M39 is committed + pushed (`fc6bf91`). M40 (this removal) is **code-complete, uncommitted** —
  6 files: `editor.gd`, `stage.gd`, `interpreter.gd`, `block_view.gd`, `pong_scripts.gd`, `editor.tscn`.
- **Immediate next action (two parts):**
  1. **Adapt the existing saves to the new flat format** (the explicitly-deferred step-2). `platformer.json`
     and its generator `build_platformer.py` are in the old `{scenes, active}` shape with **3 scenes**
     (level1/2/3). The new loader only reads `{scripts, variables, background, grid}`, so they won't open
     as-is. Decide how to collapse the 3 levels to one stage (keep level1? merge?) and rewrite the
     generator to emit the flat shape, then regenerate `platformer.json`.
  2. **F5-verify M40** — launch the editor: no scene selector/buttons in the top bar; the stock Pong demo
     loads, RUN plays it, ESC returns with edits intact; SAVE writes `{scripts, variables, background,
     grid}` and OPEN reloads it; the palette has no SCENES group.

## Next up (candidate milestones)

Drawn from `CLAUDE.md` → *Deliberately deferred*. Pick one per milestone; stay scoped.

- **Custom-block *parameter* rename/sync + delete.** M32 did the *name* cascade; editing a `define`'s
  *params* should rewrite its `call`s' `args` keys and its body's `param`s — but first needs a **params-
  editing UI** (no way to edit params after the Make-a-Block dialog today) plus a rename-vs-add/remove
  heuristic (params are name-keyed, no stable ids). Also: **delete** a custom block from the UI (remove
  the `define` + strip its `call`s — the My-Blocks twin of M21's variable delete).
- **Boolean custom-block parameters / return value** — M31 did value params; a boolean param needs a
  boolean `param` output + boolean arg slot + a dialog way to mark it; a return value would make a
  custom block usable as a reporter (Scratch keeps them statements).
- **Live embedded run** — a `SubViewport` stage panel beside the canvas (the M26 restructure);
  current RUN/ESC is a full scene swap.
- **Full-body grab of an all-field pill / eject-or-wrap a displaced reporter.**
- **Per-sprite "revert"** to stock script (NEW already resets the whole project).

## Recently shipped

(Newest first. Move items here as they land + commit.)

- Platformer — **grid/screen conformance + side-wall collision.** Reshaped every sprite in
  `build_platformer.py` so all centers and sizes are multiples of the default 8px grid and fit inside the
  fixed 480×352 screen (player now 16×32 resting at grid-aligned y=304; platforms/coins/goal/HUD all
  snapped; added a ground-level `Wall` pillar). Reworked the player physics into a **separate-axis
  collision response**: a horizontal pass (`vx`) moves then steps back out of any solid it lands in — so a
  platform's *side* stops the player like a vertical wall (they slide along it) — followed by the original
  vertical pass (`vy`) for floors/ceilings. Pure save-file change (existing opcodes only); regenerate with
  `python3 build_platformer.py`. *(committed/pushed: pending)*

- M40 — **multiple-stage functionality removed.** Reverted the M33/M34 scene (stage/level) layer back to
  a single flat project: editor owns `_scripts`/`_variables`/`_background`/`_grid_settings` directly (no
  `_scenes` list / active index / scene chrome), the Stage takes `project_sprites`/`project_variables`/
  `project_background` again, `switch_scene`/`next_scene` + the `scenes` category + `project_scene_names`
  are gone, `PongScripts.scenes()` removed, and persistence is back to `{scripts, variables, background,
  grid}` (no backward-compat). 6 files touched. *(committed/pushed: pending)*
- M39 — **stage-editor world grid.** The Stage view's fine alignment grid now spans the whole pannable
  view, and the screen-boundary indicator is tiled into a grid of 480×352 screen cells in all directions
  (default/origin screen highlighted: bg fill + bright border; neighbours dimmed). One full-view,
  pan-fixed `_GridLayer` replaced M27's clipped `_screen_panel`. Editor-side only — no block/runtime
  change. *(committed `fc6bf91`)*
- M38 — **web export save/open.** SAVE / OPEN work on a Web (WebAssembly) build via a transport split:
  desktop `FileAccess` vs. browser download / `<input type=file>` upload, behind `OS.has_feature("web")`,
  reusing the same `_serialize_project` / `_apply_project` model halves. No block/runtime change.
- Bugfix — **open project now survives the RUN → ESC round trip.** ESC reloaded `editor.tscn`, whose
  `_ready` always `_seed_demo()`'d, so the editor came back as the stock demo and discarded the open
  project + unsaved edits. Fix: `_on_run` stashes the project (`_restore_*` statics — the deep copy it
  already hands the Stage, plus the active scene + bound file path), and `_ready` calls a new
  `_restore_project()` instead of `_seed_demo()` when `_restore_pending` is set ([`editor.gd`](scripts/editor.gd)).
- M36 — curved (convex) paddle bounce in the demo: the rebound angle tracks the contact point on the
  paddle (centre → straight back, ends → steep deflection). Existing opcodes only; pure
  `pong_scripts.gd` edit. *(committed `21eb50f`)*
- M35 — motion-state reporters (`direction`/`x_position`/`y_position`) + the Pong ball's bounce
  decomposed into blocks (sign-gated reflection + `go_to` nudge), retiring the `"bounce"` sentinel in
  the demo. *(committed `00108ea`)*
- M34 — runtime scene navigation: `switch to scene {name}` / `next scene` blocks change the playing
  scene at run time; the runtime carries the whole scene list. *(committed `be3da68`)*
- M33 — multiple stages (scenes / levels): a project holds several independent scenes, switchable in
  the editor; RUN plays the active one. *(code complete, uncommitted)*
- M32 — custom block rename cascade (renaming a `define` rewrites its `call`s).
- M31 — custom block parameters (`define` params + `call` args + `param` reporter).
- M30 — custom blocks (`define`/`call`, "My Blocks").
- M29 — arithmetic evaluated in a numeric slot (`2+3` → `5`).
- M28 — aspect-locked resize on the stage (Shift to lock proportions).
- M27 — static stage (scene) editor + grid + background.
- M26 — editor resolution decoupled from the fixed 480×360 runtime viewport.

---

## Working agreements

These are the standing rules for this project (also recorded in Claude's memory):

- **Commit + push after every feature — without asking.** When work is code-complete, commit and
  **`git push` immediately** (don't batch, don't wait for approval or a manual F5-verify — the remote
  history is the backup/undo). Branch off `main` first if not already on a working branch.
- **Update this HANDOFF.md after every feature**, alongside the `CLAUDE.md` milestone write-up.
- **Git identity:** commit as `nedink@gmail.com` here (not the global work email).
- **Commit message convention:** `M<n>: <short description>` matching the milestone.

## Testing

- **Claude cannot run Godot** — there's no CLI for it in this environment. The user tests
  manually by pressing **F5** in the Godot editor (main scene = `editor.tscn`).
- So: commit + push when code-complete, **then** describe what to look for so the user can F5-verify
  (verification no longer gates the commit — the remote is the safety net).

## Extending (quick pointer)

Full guidance is in `CLAUDE.md` → *Conventions for extending*. The one-line version:
**a new block = one `interpreter.gd` handler + one `block_view.gd` `_OPCODES` entry.** Keep blocks
as plain `{opcode, inputs}` dicts; long-running blocks must `await` a frame/timer.
