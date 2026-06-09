# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M30 — custom blocks ("My Blocks": `define {name}` hat + `call {name}`).
- **Git:** last commit is `8b56077 M29`. **M30 is implemented but NOT yet committed** — working
  tree has uncommitted changes to `CLAUDE.md`, `editor.tscn`, and `scripts/{block_canvas,
  block_palette,block_view,editor,interpreter}.gd`.
- **Immediate next action:** verify M30 works (F5 — manual; see [testing](#testing)), then commit
  + push it as `M30: custom blocks (define + call, "My Blocks")`.

## Next up (candidate milestones)

Drawn from `CLAUDE.md` → *Deliberately deferred*. Pick one per milestone; stay scoped.

- **M31 — custom-block rename/delete cascade.** Editing a `define`'s name should rewrite the
  `call`s that target it (today they dangle → runtime warning). M21 (variable rename) / M25
  (sprite rename) are the exact template — walk `define`/`call` the way they walk
  `set_var`/`touching_sprite?`.
- **Custom-block parameters / return value** — needs a parameter frame in `interpreter.gd` and
  procedure-scoped parameter reporters in the editor. A milestone of its own.
- **Live embedded run** — a `SubViewport` stage panel beside the canvas (the M26 restructure);
  current RUN/ESC is a full scene swap.
- **Full-body grab of an all-field pill / eject-or-wrap a displaced reporter.**
- **Per-sprite "revert"** to stock script (NEW already resets the whole project).

## Recently shipped

(Newest first. Move items here as they land + commit.)

- _M30 — custom blocks (`define`/`call`). **Pending commit.**_
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
