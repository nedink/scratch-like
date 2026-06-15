# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M34 — **runtime scene navigation**. Two new blocks change the playing scene
  at run time: **`switch to scene {name}`** (a dropdown of the project's scenes) and **`next scene`**
  (advance, wrapping). Adds **two opcodes** (`switch_scene`/`next_scene`, in a new `scenes` palette
  group) but no block-data-shape change. The runtime now carries the **whole** scene list:
  `editor._on_run` hands `Stage.project_scenes` (the full `[{name, sprites, variables, background,
  grid}]` list) + `Stage.project_active` (replacing M24/M20/M27's three per-scene statics). A block
  re-points the static `project_active`, `stop_all`s the current scripts, and reloads the game scene via
  `change_scene_to_file` — the same swap RUN/ESC use, so `Stage._ready` rebuilds on the target with **no
  bespoke teardown** (`go_to_scene_by_name`/`go_to_next_scene`/`_change_to_scene` in `stage.gd`;
  `_active_scene`/`_scene_list` read per-scene fields off the active dict). Editor: `_scene_names` feeds
  `BlockView.project_scene_names` (the dropdown source), re-pointed on every project load + scene rename.
- **Git:** ⚠️ **uncommitted.** Per the session's `git status`, **M33** sits uncommitted in the working
  tree (CLAUDE.md, editor.tscn, editor.gd, pong_scripts.gd modified) — M32 *is* committed (`f592341` +
  `80d4736`). **M34** (this) is now layered on top, also uncommitted, touching stage.gd, interpreter.gd,
  block_view.gd, editor.gd + docs. There are also stray untracked files (`build_platformer.py`,
  `platformer.json`) — unrelated, leave them. Decide how to split/commit M33 then M34 before pushing.
- **Immediate next action:** F5-verify M34 (see [testing](#testing)); commit M33 + M34; then pick the
  next milestone from [Next up](#next-up-candidate-milestones).

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

- M34 — runtime scene navigation: `switch to scene {name}` / `next scene` blocks change the playing
  scene at run time; the runtime carries the whole scene list. *(code complete, uncommitted)*
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

- **Commit + push after every feature.** Branch off `main` first if not already on a working
  branch. Commit, then **`git push` immediately** — don't batch.
- **Update this HANDOFF.md after every feature**, alongside the `CLAUDE.md` milestone write-up.
- **Git identity:** commit as `nedink@gmail.com` here (not the global work email).
- **Commit message convention:** `M<n>: <short description>` matching the milestone.

## Testing

- **Claude cannot run Godot** — there's no CLI for it in this environment. The user tests
  manually by pressing **F5** in the Godot editor (main scene = `editor.tscn`).
- So: after implementing, describe what to look for, and ask the user to F5-verify before commit.

## Extending (quick pointer)

Full guidance is in `CLAUDE.md` → *Conventions for extending*. The one-line version:
**a new block = one `interpreter.gd` handler + one `block_view.gd` `_OPCODES` entry.** Keep blocks
as plain `{opcode, inputs}` dicts; long-running blocks must `await` a frame/timer.
