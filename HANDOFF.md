# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M37 — **stage-editor world view, panning, and camera blocks**. Three things:
  ① the **stage editor shows the whole game world** (no longer clipped to the 480×352 screen) with the
  screen marked by a **bright guide-line border**, **pan by dragging the background**, a **Recenter view**
  button (inspector), and **opaque panels** framing the top bar + the right inspector
  ([`stage_view.gd`](scripts/stage_view.gd), [`editor.tscn`](editor.tscn), one wire in
  [`editor.gd`](scripts/editor.gd)). ② a new **CAMERA block group** — `set camera to x: y:`,
  `change camera by x: y:`, `camera follow {sprite}`, `camera stop following` (4 new opcodes,
  [`block_view.gd`](scripts/block_view.gd) + one-line handlers each in
  [`interpreter.gd`](scripts/interpreter.gd)). ③ the **runtime camera** — [`stage.gd`](scripts/stage.gd)
  adds a `Camera2D` centred at (240,176) (= today's identity view, so a project with no camera blocks is
  unchanged), follows a sprite each frame via `_process`, and the background ColorRect moved onto a
  `CanvasLayer(-1)` so it stays screen-fixed while the camera pans. Camera coords = sprite coords (the
  world point shown at screen centre). No block-data-shape change; saves ride existing persistence.
- **Git:** M37 code + docs complete, **committed + pushed**. The stray untracked files
  (`build_platformer.py`, `platformer.json`) remain unrelated — leave them.
- **Immediate next action:** F5-verify M37 (see [testing](#testing)) — in **Stage** mode the off-screen
  Announcer is now visible, the screen region is outlined, dragging empty background pans, Recenter
  re-frames, sprite drag/resize still work, the bar + inspector read as solid panels; in a script build
  `when flag clicked → forever → camera follow {Ball}`, RUN and confirm the view scrolls to keep the ball
  centred; with no camera blocks the demo plays exactly as before. Then pick the next milestone from
  [Next up](#next-up-candidate-milestones).

## Next up (candidate milestones)

Drawn from `CLAUDE.md` → *Deliberately deferred*. Pick one per milestone; stay scoped.

- **Cross-scene shared state (M34 follow-on).** A project-global variable store carried across scenes,
  so e.g. a score survives a `switch_scene` (variables are per-scene today, re-seeded on every switch).
- **Scene-rename → `switch_scene` cascade (M34 follow-on).** Renaming a scene relabels the dropdown but
  leaves existing `switch_scene` blocks naming the old scene (→ runtime warning). `rewrite_sprite_refs`
  (M25) is the template, but here it's a *cross-scene* walk (any scene's block can name any scene).
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
