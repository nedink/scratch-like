# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M31 — custom block **parameters** (value/number-text only): `define`
  declares `params`, `call` carries `args`, a new `param` reporter reads a per-call parameter frame.
  A `param` pill's drops are **confined to its own define's body** (`BlockCanvas._nearest_slot` →
  `_scoped_slots`/`_enclosing_define_body`) — you can't drop a parameter into a block outside the
  function that declares it; releasing it elsewhere discards it.
- **Git:** last commit is `85ecdff M30`. **M31 is implemented but NOT yet committed** — working
  tree has uncommitted changes to `CLAUDE.md`, `HANDOFF.md`, `editor.tscn`, and `scripts/{block_canvas,
  block_palette,block_view,editor,interpreter}.gd`.
- **Immediate next action:** verify M31 works (F5 — manual; see [testing](#testing)), then commit
  + push it as `M31: custom block parameters`.

## Next up (candidate milestones)

Drawn from `CLAUDE.md` → *Deliberately deferred*. Pick one per milestone; stay scoped.

- **Custom-block rename/sync cascade.** Editing a `define`'s name *or its params* should rewrite the
  `call`s/`param`s that target it (today they keep stale arg keys / dangle → runtime warning). M21
  (variable rename) / M25 (sprite rename) are the exact template — walk `define`/`call`/`param` the
  way they walk `set_var`/`touching_sprite?`.
- **Boolean custom-block parameters / return value** — M31 did value params; a boolean param needs a
  boolean `param` output + boolean arg slot + a dialog way to mark it; a return value would make a
  custom block usable as a reporter (Scratch keeps them statements).
- **Live embedded run** — a `SubViewport` stage panel beside the canvas (the M26 restructure);
  current RUN/ESC is a full scene swap.
- **Full-body grab of an all-field pill / eject-or-wrap a displaced reporter.**
- **Per-sprite "revert"** to stock script (NEW already resets the whole project).

## Recently shipped

(Newest first. Move items here as they land + commit.)

- _M31 — custom block parameters (`define` params + `call` args + `param` reporter). **Pending commit.**_
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
