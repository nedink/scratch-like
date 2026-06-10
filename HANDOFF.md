# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Milestone in flight:** M32 — custom block **rename cascade**. Editing a `define`'s name field in
  place on the canvas now rewrites this sprite's `call`s to match (the custom-block analog of M21's
  variable rename / M25's sprite rename, scoped per-sprite since custom blocks are per-sprite). The
  walk is `BlockView.rewrite_custom_block_refs` (define + call by `inputs.name`); the trigger is the
  in-place name commit — `_define_header` stamps the name field `define_name`, `BlockCanvas._commit_literal`
  catches it, validates uniqueness (`_other_define_named`, blank/duplicate → revert), and defers
  (`call_deferred`, so it doesn't free the committing field) `_rename_custom_block_deferred`, which
  rewrites the calls and fires `on_custom_block_renamed` → `editor._on_custom_block_renamed` (re-derive
  the sprite's block names + params, rebuild palette, refresh canvas). **`param` reporters and `call`
  `args` keys are untouched** — they bind to parameters, not the block name.
- **Git:** last commit is `f592341 M32: custom block rename cascade` (committed + pushed to `main`).
- **Immediate next action:** F5-verify M32 (see [testing](#testing)) if not already done; then pick
  the next milestone from [Next up](#next-up-candidate-milestones).

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
