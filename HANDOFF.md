# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M36 — **curved (convex) paddle bounce in the demo**. The Pong paddles now
  deflect the ball as if they bulge toward the centre of the playfield: the rebound angle tracks **where**
  the ball strikes — centre → straight back, an end → steep deflection toward that end (classic arcade
  Pong). **Demo-only** follow-on to M35: a pure [`PongScripts`](scripts/pong_scripts.gd) edit using
  **only existing opcodes** — **no new opcode, no block-data-shape change, no runtime change, no editor
  change**. Mechanism: each paddle **publishes its centre y into a global** every tick (`set
  left_paddle_y / right_paddle_y to (y position)` in `_paddle`; two new globals in `variables()`),
  because M35's `y_position` reads the *running* sprite (the ball can't read another sprite directly).
  The ball reads the offset of its own y from the paddle's relayed y and aims off straight-back by
  `offset × PADDLE_BOUNCE_CURVE` (0.9 °/px): LEFT → `90 + offset×curve`, RIGHT → `270 − offset×curve`.
  M35's sign-gate + `go_to` nudge are kept; the gated angle range (`90/270 ± ~50°`) stays heading-away,
  so no double-flip/stick.
- **Git:** M36 code + docs complete, **uncommitted** — F5-verify first. (Note: M35 itself is already
  committed as `00108ea` — the prior HANDOFF was stale on that.) The stray untracked files
  (`build_platformer.py`, `platformer.json`) remain unrelated — leave them.
- **Immediate next action:** F5-verify M36 (see [testing](#testing)) — play Pong, confirm the ball
  bounces off both paddles with an angle that depends on the contact point (centre ≈ straight back, ends
  deflect steeply), still bounces flat off the top/bottom walls, never sticks, and re-serves on a miss;
  then commit + push and pick the next milestone from [Next up](#next-up-candidate-milestones).

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

- M36 — curved (convex) paddle bounce in the demo: paddles relay their centre y into a global and the
  ball aims its rebound off straight-back by its contact offset × `PADDLE_BOUNCE_CURVE`. Existing opcodes
  only; pure `pong_scripts.gd` edit. *(code + docs complete, uncommitted)*
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
