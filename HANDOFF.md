# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **In flight (on `m41-animation-blocks`):** **`zombie.json`** — a top-down zombie-survival game built
  in the block language, plus the **four new opcodes** it required (the existing block set couldn't
  express mouse-aim, homing, or recolouring):
  - **`mouse_x` / `mouse_y`** (sensing reporters) — cursor position in world coords via
    `Stage.get_global_mouse_position()`.
  - **`point_towards x: {x} y: {y}`** (motion statement) — face a world point (`atan2(dx, -dy)`); the
    data-form of `point_in_direction` (the block set has no trig). Drives mouse-aimed bullets *and*
    zombies homing on the player.
  - **`set_color {hex}`** (looks statement) — regenerate the placeholder costume as a solid fill (the
    player's black↔white hit-flash); the costume complement of `say`.
  - All four are the usual one-`interpreter.gd`-handler + one-`block_view.gd`-`_OPCODES`-entry step; no
    block-data-shape change, so persistence/RUN/editor carry them untouched.
  - **Game design** (17 sprites, no clones — `touching_sprite?` can't see clones, and collision is
    central, so zombies/bullets are **named pooled sprites**): WASD move + screen-wrap (navigable =
    screen + 16px margin); auto-fire toward the mouse from a **3-shot clip** (shared `ammo` + a
    `fire_ready` token, auto-reload 1s when empty) across a **3-bullet pool**; a **Spawner** arms growing
    waves (`spawn_count = wave + 2`) that trickle in from off-screen via a `spawn_ready` token across a
    **10-zombie pool**, each homing on the player; on contact the zombie reports its position and the
    player's hit-handler knocks back away from it, going **invincible + uncontrollable + flashing
    black/white** (unrolled flash loop, since there's no `repeat`); **5 lives** shown top-left, GAME OVER
    + `stop all` at 0.
  - **F5-verify:** OPEN `zombie.json` → RUN. Move with WASD (wraps at the 16px margin), bullets stream
    toward the cursor and reload after 3, green zombies trickle in from the edges and chase you; running
    into one knocks you back flashing; the top-left counter falls 5→0 then "GAME OVER".
- **Last shipped:** M41 — **animation blocks** (tween a variable over time). One new statement opcode,
  **`animate {name} to {value} over {seconds} secs {easing}`** (new slate-orchid `"animation"` palette
  category), with `{easing}` ∈ {`linear`, `ease in`, `ease out`}. `{name}` is a data-scoped variables
  dropdown (the `set_var`/`variable` source — so **no editor change**), `{value}`/`{seconds}` numeric
  slots. The interpreter's `_on_animate` is a coroutine like `wait_seconds`: it snapshots start+target,
  then each fixed physics tick writes `lerpf(start, target, _ease_fraction(easing, t))` through
  `_set_variable`, **blocking the script for the duration** and polling the Stage/`_alive` flags so a
  `stop` unwinds it mid-tween (it snaps onto the target only on completion). Easing: linear `t`,
  ease-in `t²`, ease-out `1−(1−t)²`. Pure `interpreter.gd` + `block_view.gd` (the M37 camera-block
  shape). Animating a *variable* is the general primitive — wire it into `go to`/`point in
  direction`/`say` for the actual motion.
- **Demo update (rides M41):** the Pong **right paddle is now a CPU paddle** — it auto-animates up/down
  its rail with the `animate` block instead of answering keys, and the **arrow keys moved to the left
  paddle** (which now answers W/S *or* ↑/↓). Pure `pong_scripts.gd` change (existing blocks only, like
  M36 was for M35).
- **Follow-up polish (on the M41 branch):** ① **paddle y-limits now track the current screen.** The
  runtime screen is 480×**352** (`Stage._GAME_SIZE`) but `pong_scripts.gd` still carried the old 480×360
  values — `PADDLE_BOTTOM_Y` 312→**304** (= 352−48 half-height) and serve `CENTER` y 180→**176**
  (= 352/2). ② **block-editor layout** — palette groups now read as distinct groups (a `_GROUP_GAP`
  spacer above each category header in `block_palette.gd`, instead of a header floating equidistant
  between two groups), and the whole editor `Page` is inset 8px from the window edges (`editor.tscn`
  offsets) so the bar/palette/canvas aren't flush against the frame.
- **Git:** M41 on branch `m41-animation-blocks`. Opcode work: `interpreter.gd`, `block_view.gd`; demo
  update: `pong_scripts.gd` (+ docs).
- **F5-verify M41 (block):** an ANIMATION group appears in the palette with the `animate` block; drag e.g.
  `when_flag_clicked → animate x to 400 over 2 secs ease out` plus `forever → go to x: (x) y: 100` onto a
  sprite (make an `x` variable first), RUN — the sprite glides right and decelerates to a stop over ~2s;
  swap the easing to `ease in` (slow start) / `linear` (constant) to feel the curve. `stop` mid-tween
  leaves it partway.
- **F5-verify demo:** RUN the stock demo — the **right paddle should glide up and down on its own**
  (easing to a stop and reversing at each end); play the **left paddle with W/S *and* the arrow keys**.
  The ball should still bounce convex off the moving right paddle (the curved-bounce relay still works).

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

- Demo — **right paddle auto-animates; arrow keys move to the left paddle (rides M41).** A pure
  `pong_scripts.gd` change exercising the M41 `animate` block (no block-language/runtime edit, like M36
  was for M35). The right paddle gave up keys to glide top↔bottom forever via two `animate`s on
  `right_paddle_y` (`ease out`, decelerating into each turn) in one hat, with a second hat
  `forever → go to x: 456 y: (right_paddle_y)` doing the actual node move (animate blocks its script).
  Animating `right_paddle_y` directly keeps the ball's curved-bounce relay correct for free. `_paddle`
  generalized to key *lists* (`_keys_pressed` ORs them) so the left paddle answers W/S *and* ↑/↓.
  *(committed/pushed: pending)*

- M41 — **animation blocks.** One new statement opcode `animate {name} to {value} over {seconds} secs
  {easing}` (new `"animation"` palette category) that tweens a variable from its current value to a
  target over a duration, with `linear` / `ease in` (t²) / `ease out` (1−(1−t)²) interpolation.
  `_on_animate` is a `wait_seconds`-style coroutine yielding on the fixed physics tick, writing through
  `_set_variable` and polling Stage/`_alive` so a `stop` unwinds it mid-tween. Pure `interpreter.gd` +
  `block_view.gd` — no editor change (reuses the `data_enums "variables"` dropdown + an `enums` easing
  dropdown). *(committed/pushed: pending)*

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
