# HANDOFF — session-to-session continuity

A lightweight running log for picking up where the last session left off. `CLAUDE.md` is
the deep, permanent design record (one section per milestone); **this file is the volatile
top-of-stack** — what's in flight right now, what to do next, and the working agreements.

> **After every new feature/milestone:** ① commit, ② push, ③ update this file (move the
> finished work into "Recently shipped", refresh "Current state" and "Next up"). See
> [Working agreements](#working-agreements). Also fold the milestone into `CLAUDE.md` as usual.

---

## Current state

- **Just shipped — M51: keyboard authoring mode (cursor + fuzzy block picker).** The block editor is
  now fully keyboard-drivable *alongside* mouse drag/drop. A keyboard **cursor** (`BlockCanvas._cursor`,
  editor-only UI state like selection/collapse, never serialized, stored as data references so it
  survives `_render`) sits at a **statement gap**, an **input slot**, or a **"new stack here"** point;
  a bright-green caret overlay (`_caret`) marks it. **Click** a block/slot/empty-canvas to place it;
  **↑/↓** walk statement gaps in document order (`_ordered_gaps`), **←/→/Tab** walk a block's header
  slots (descending into nested reporter pills); **Enter** or **typing** opens a **fuzzy picker** (a
  lazy `PopupPanel` + `LineEdit` + `ItemList`, `_ensure_picker`) that filters opcodes by their
  natural-language label (`BlockView.opcode_label`/`opcode_template`); choosing inserts a fresh
  `make_block` at the cursor. At a slot the picker is **type-filtered to reporters** (the M23
  `slot_type` rule); choosing a reporter with operands **descends into its first operand** — so nested
  expressions like `move (score + 1)` are built recursively, no text parser — while a **leaf** reporter
  (no operands) **advances the cursor to the gap after the owning statement** (the same end-ward flow a
  picked statement makes), so picking e.g. `score` into `move`'s slot doesn't strand the caret on that
  slot. Typing on a **literal**
  slot focuses its field; **Backspace/Delete** deletes at the cursor; **Escape** dismisses. Pure
  editor-side: only `block_canvas.gd` (the bulk) + two tiny `block_view.gd` accessors; **no opcode /
  data-shape / runtime / editor.gd change**.
  - **⚠ Not F5-verified** (Claude can't run Godot). **F5-verify:** (1) click empty canvas → green caret;
    type "flag", Enter → `when flag clicked` lands, caret drops into its body; Enter again, type "move"
    → `move 10 steps` nests inside. (2) On `move`'s steps slot, type "+" → `(0 + 0)` nests, caret in the
    first operand; fill it, Tab to the second. (3) On an `if` condition the picker offers only boolean
    reporters. (4) ↑/↓ walk statements, ←/→/Tab walk slots, Backspace deletes at the caret, Escape
    clears (and does **not** quit the editor while a cursor is active). (5) Mouse drag/drop, literal
    click-edit, selection (M46), collapse (M47) all still work; collapsed stacks are skipped by ↑/↓.
    Then **RUN** a keyboard-built script — runs identically to a drag-built one; **SAVE/OPEN** round-trips.
- **Earlier — a new project starts with one sprite named "Sprite".** `_seed_blank`
  ([`editor.gd`](scripts/editor.gd)) now seeds the default/NEW project with a single `_DEFAULT_SPRITE`
  named `"Sprite"` (grey placeholder at stage centre, empty script) instead of zero sprites. The blank,
  spriteless default and the stale `_update_add_sprite_blink` doc reference are gone;
  `_load_project_into_ui` already selects sprite 0 when one exists, so the selector lands on "Sprite"
  with no extra wiring.
  - **⚠ Not F5-verified** (Claude can't run Godot). **F5-verify:** launch (or click NEW) → sprite selector
    shows "Sprite" selected, an empty canvas, stage view shows one grey square at centre.
- **Earlier — collapse chevron moved into the block header.** The M47 collapse toggle used to sit in
  a fixed-width left **gutter** beside each stack (`▼`/`▶`). It now lives **inside the first block's
  header**, right-justified via an `SIZE_EXPAND_FILL` spacer (so on a hat/C-block — panel as wide as its
  body — it sits the full block width from the text), and the glyph is plain ASCII (**`-` expanded / `+`
  collapsed**) so it renders in the **web export** instead of tofu-ing like the geometric triangles. All
  in [`block_canvas.gd`](scripts/block_canvas.gd): `_wrap_with_gutter`/`_GUTTER_W`/`_ROW_SEP` removed,
  new `_add_collapse_chevron` + `_first_header`, `_land_pos` simplified to `_ghost.position` (no gutter to
  subtract). Toggle logic unchanged — the chevron still carries the `collapse_stack` meta and
  `_collapse_toggle_at` finds it by global rect.
  - **⚠ Not F5-verified** (Claude can't run Godot). **F5-verify:** Blocks mode — a multi-block hat shows a
    `-` at its top-right; click it → folds to a one-line bar showing `+`; click → expands. Also check the
    **web build** renders the `+`/`-` (not boxes). Single-block scripts show no chevron.
- **Earlier — mobile editor resolution.** The editor's logical layout size (`_EDITOR_SIZE`,
  1280×800) shrinks to `_EDITOR_MOBILE_SIZE` (640×400) when `_is_mobile()` — a native mobile export, a
  mobile *web* export (`web_android`/`web_ios`), or a narrow web window (<800px wide). A smaller logical
  size makes each logical pixel cover more device pixels, so the chrome/blocks render **bigger** and stay
  tappable on a phone. Editor-only: the **game** stays at its fixed 480×352 viewport (`stage.gd`, load-
  bearing for `go_to`/edge/pixel-art), already letterboxed+scaled to fit any screen via ASPECT_KEEP.
  - **⚠ Not F5-verified** (Claude can't run Godot). **F5-verify:** on a desktop browser, narrow the
    window below 800px before load → editor chrome should come up noticeably larger; full-width →
    unchanged. The game (RUN) should look the same on both.
- **Earlier — M50: category recolours are per-project, not a global edit.** M49 saved a category
  recolour to `blocks/block_styles.tres` (a permanent global change, shared by every project); M50 moves
  it into the **project `.json`** so a recolour rides with that project — it loads when the project opens
  and resets on NEW, and any category the project doesn't recolour draws its **default**. The editor owns
  a new `_block_colors` model (category → hex string), seeded `{}` by `_seed_demo`, serialised under a
  top-level **`block_colors`** key (`_serialize_project` / `_apply_project` — optional, so a pre-M50 save
  opens with no overrides), stashed across the RUN→ESC round trip (`_restore_block_colors`), and pushed
  to the new static `BlockView.project_block_colors` on every project load (`_sync_block_colors`, the
  colour twin of `_sync_background`). `BlockView.category_color` now reads that project override first,
  else `default_category_color` (the `BlockStyles` `.tres` / `_CATEGORY_COLORS` default). The palette
  picker no longer writes the `.tres`: `BlockView.set_category_color` / `save_styles` are **removed**, and
  the palette calls back to the editor via new `_on_recolor_category(cat, color)` (live: writes
  `_block_colors` + `project_block_colors` + `_canvas.refresh()`) and `_on_reset_category(cat)` (clears the
  override). Picker close just rebuilds the chips (persistence already happened live). `BlockStyles`
  (`block_styles.gd` / `.tres`) stays as the inspector-editable **default** provider (M48); the working
  `.tres` was reverted to stock (the `control`/`motion` edits baked in by M49 testing are gone).
  - **⚠ Not F5-verified** (Claude can't run Godot). **F5-verify:** Blocks mode — click a section title →
    picker opens, category recolours live as you pick; **SAVE** the project, relaunch, **OPEN** it → the
    colour comes back; **NEW** → all categories return to defaults; the recoloured project's `.json` has a
    `block_colors` entry. "Reset to default colour" returns a category to stock and drops it from the
    project. `blocks/block_styles.tres` should **no longer** change when you recolour in-app. RUN→ESC keeps
    the colours.
- **Earlier — M49: recolour a block category from its palette header.** Click a section title in
  the palette (the coloured header bars — MOTION, CONTROL, …, plus MY BLOCKS / LISTS) to open a colour
  picker; blocks in that category recolour **live** as you pick. Each group title is a **flat `Button`**
  (`BlockPalette._add_group_header` — colour-fonted title, transparent, like the M48 `Label`) that on
  click pops a **shared `ColorPicker` in a `PopupPanel`** (`_ensure_color_popup`, reused across categories,
  skipped by `rebuild()`). A `ColorPickerButton` was the first attempt but paints its swatch over the
  whole button, hiding the title — hence the separate picker. `color_changed` → `_on_category_color_changed`
  → `_apply_recolor` (recolours the header + applies live; no palette rebuild — would free the open
  picker); `popup_hide` → `_on_category_color_committed` (deferred `rebuild()` re-tints the chips). A
  **"Reset to default colour"** button under the picker restores a category's stock hue. (M49 persisted to
  the `.tres`; **M50 above changed that to per-project**.)
- **Earlier — M48: block rendering via editable Godot scenes.** The block visuals are no longer
  hand-built in code: `BlockView` now **instantiates one `.tscn` shell per shape** (`blocks/*.tscn`) and
  populates it, so block styling — corner radii, padding, borders, fonts, layout, decorations — is
  edited **visually in the Godot editor**. Per-category *colour* stays data-applied (it's keyed by the
  block's category) from an **editable `BlockStyles` resource** (`blocks/block_styles.tres`, one `Color`
  per category in the inspector); `BlockView._tint()` duplicates a shell's stylebox and overrides only
  `bg_color`, so shape edits survive and the canvas's selection-outline still works. **No opcode /
  data-shape / runtime change, and no canvas/palette change** — they walk the rendered tree generically
  by meta (`blk_array`/`slot_inputs`/`slot_type`/…), which `BlockView` still stamps on the same nodes.
  Scenes: `statement_block` (hats/C-blocks too — exposes `%Content`), `reporter_pill` / `boolean_pill`,
  `number_field` / `text_field`, `enum_field`, `empty_slot`, `collapsed_bar` (exposes `%Row`). Files:
  new `blocks/` dir + `scripts/block_styles.gd`; `block_view.gd` (`build_block` / `build_reporter` /
  `build_collapsed_stack` / `_param_pill` / `_literal_field` / `_enum_field` / `_empty_slot` now
  `instantiate()` + `_tint`; `_box`/`_BLOCK_PAD` removed; `category_color` reads the resource).
  - **⚠ Not F5-verified** (Claude can't run Godot, and `.tscn`/`.tres` parse can't be checked here).
    Hand-authored in format-3, comment-free, minimal. **F5-verify:** Blocks mode — every block, pill,
    field, dropdown, empty C-slot, and collapsed bar should look **identical to before**; categories keep
    their colours; editing literals, dropping/dragging reporters, selection outline, collapse all still
    work. Then open `blocks/statement_block.tscn` (or `block_styles.tres`) in the Godot editor, tweak it,
    and re-run to see the restyle apply to every statement block.
- **Earlier (editor convenience):** the **block palette is resizable** — it's wider by default
  (min width 150 → 240, so the 220px chips no longer overflow into a horizontal scrollbar) and a
  **draggable divider** (`PaletteResizer`, a thin handle between the palette and the canvas, HSIZE
  cursor) sets the palette's width. Editor-side only: the handle's `gui_input` adds the drag delta to
  `_palette_scroll.custom_minimum_size.x` (clamped 120–600) in `editor._on_palette_resizer_input`; it's
  shown only in Blocks mode (toggled in `_set_mode`). No opcode / data-shape / runtime change.
  - **F5-verify:** Blocks mode — palette is wider and chips fit without a horizontal scrollbar. Hover the
    divider between palette and canvas → resize cursor; drag it → palette widens/narrows, canvas fills the
    rest. Switch to Stage/Paint → the handle disappears. (Stage/Paint inspectors unaffected.)
- **Earlier (on `m41-animation-blocks`):** **M46 — multi-block selection**, now extended so
  **reporters can live free on the canvas** (Scratch's loose reporter) and are manipulated/selected like
  statements. Select blocks in the block canvas: **click** (Shift/Cmd-click to toggle) — statement
  blocks, in-slot reporter pills, **and free-floating reporters**; **double-click** (the block +
  everything after it in that script, **plus every block nested inside** — a C-block's body and any
  reporter input pills, recursively — `_select_subtree`); or **rubber-band** over empty canvas (sweeps
  statements + free reporters); then **drag to move together**, **Delete/Backspace**, or **Cmd/Ctrl+D**.
  **New in this pass — free-floating reporters:** dropping a reporter off every slot (from the palette or
  pulled out of a slot) now **lands it as its own top-level stack** (`_drop`) instead of discarding it;
  `BlockView.build_stack` renders a stack-level reporter as its **pill** (still stamping
  `blk_array`/`blk_index`), so it drags/selects like a statement (`_block_at`/`_hit_is_reporter` route its
  pickup to `_begin_reporter_drag`, which now handles both the in-slot and free origins). A loose reporter
  is **inert at runtime** (`run()` starts only hats) but persists with the project. Group ops act on
  stack-level picks (statements + free reporters); an *in-slot* pill stays highlight-only — pull it out
  first. Editor-side; the only `BlockView` touch is the one `build_stack` line; no opcode / data-shape /
  runtime change. (Prior pass: selectable in-slot pills + double-click-selects-children. Before that:
  **M45 — pixel costume editor**.)
  - **F5-verify:** Blocks mode. Drag a reporter (`score`, `+`) from the palette onto **empty canvas** →
    it stays there as a pill. Pull a reporter out of a slot and drop on empty canvas → it stays (was
    discarded before). Grab a free-floating reporter → drag it into a slot / elsewhere / onto the palette
    (deletes). Click it → white outline; double-click → it + its nested input pills outline; rubber-band
    over it → selected; Delete / Cmd+D act on it. RUN a project with a parked reporter → plays normally
    (the loose reporter does nothing); SAVE→reopen keeps it. Statement selection/move/delete unchanged.
- **In flight (on `m41-animation-blocks`):** **`zombie.json`** — a top-down zombie-survival game built
  in the block language, plus the **six new opcodes** it required (the existing block set couldn't
  express mouse-aim, homing, recolouring, click-to-fire, or a resizable costume):
  - **`mouse_x` / `mouse_y`** (sensing reporters) — cursor position in world coords via
    `Stage.get_global_mouse_position()`.
  - **`mouse_down?`** (sensing **boolean** reporter) — left button held (`Input.is_mouse_button_pressed`);
    the mouse twin of `key_pressed?`. Gates click-to-shoot.
  - **`point_towards x: {x} y: {y}`** (motion statement) — face a world point (`atan2(dx, -dy)`); the
    data-form of `point_in_direction` (the block set has no trig). Drives mouse-aimed bullets *and*
    zombies homing on the player.
  - **`set_color {hex}`** (looks statement) — regenerate the placeholder costume as a solid fill (the
    player's black↔white hit-flash); the costume complement of `say`.
  - **`set size to w: {w} h: {h}`** (looks statement) — regenerate the placeholder costume at a new
    pixel size, keeping its current fill colour (sampled from pixel 0,0); the *size* twin of `set_color`.
    Draws each zombie's shrinking health bar.
  - All six are the usual one-`interpreter.gd`-handler + one-`block_view.gd`-`_OPCODES`-entry step; no
    block-data-shape change, so persistence/RUN/editor carry them untouched.
  - **`zombie.json` is now generated by `build_zombie.py`** (the `build_platformer.py` pattern): the ten
    zombies + ten health bars are near-identical, so the per-zombie logic is authored once and emitted
    N times. **Edit the generator, re-run it, don't hand-edit the JSON.** 27 sprites, 67 variables.
  - **Game design** (no clones — `touching_sprite?` can't see clones, and collision is central, so
    zombies/bullets are **named pooled sprites**): WASD move + screen-wrap (navigable = screen + 16px
    margin); **click to shoot** toward the cursor (held = auto-repeat at 0.28s) from a **3-shot clip**
    (`ammo` + a `fire_ready` token, auto-reload 1s when empty) across a **3-bullet pool**; a **Spawner**
    arms growing waves (`spawn_count = wave + 2`) that trickle in from off-screen across a **10-zombie
    pool**, each homing on the player. Four behaviours this build adds:
    - **Click to shoot** — the fire loop only arms `fire_ready` while `mouse_down?` is held.
    - **Pause on hit** — the hit-handler sets a global `zombie_pause` for the knockback/blink window;
      every zombie gates its movement on `zombie_pause == 0`, so the horde freezes for that moment.
    - **No overlap** (the platformer's revert-on-overlap pattern, both ways) — the player reverts to its
      start-of-tick position if it ends a tick touching any zombie (can't walk *into* one); a zombie,
      after advancing, registers the hit (knockback throws the player clear) then steps back out of the
      player **and** out of any other zombie it overlaps.
    - **Health bars** — each zombie has **HP** (global `z{N}_hp`, so a bullet decrements the right
      zombie's HP deterministically — `active == 1` guard, no race) and publishes its position into
      globals; a companion **HealthBar{N}** sprite follows it a few px above and `set_size`s a green bar
      to the HP fraction, parked off-screen with the zombie when it dies (HP 0). Zombies now take **3
      shots** (was 1). **5 lives** shown top-left, GAME OVER + `stop all` at 0.
  - **F5-verify:** OPEN `zombie.json` → RUN. Move with WASD; **click/hold the mouse** to fire toward the
    cursor (reload after 3). Green zombies trickle in from the edges and chase you, each under a green
    health bar that drops over 3 hits; they don't pile onto each other or onto you, and the whole horde
    **freezes for a beat** each time one tags you (you flash + get knocked back); counter falls 5→0 then
    "GAME OVER".
- **Editor fix (alongside the zombie work):** top-level stacks no longer overlap on load. `load_script`/
  `add_definition` used a fixed vertical spread (`+150`/`+120`px) that was far shorter than a tall hat
  (a `when flag clicked` with several blocks, or a `forever`), so groups overlapped — and re-flowed
  that way on every sprite switch / reopen, since canvas layout isn't persisted. New
  `BlockCanvas._reflow_stacks()` flows the stacks by their **measured** heights (it `await`s one
  `process_frame` first so the freshly-built nested min-sizes have propagated), called only on the
  default-layout paths so hand-dragged positions still survive the session.
- **Last shipped (palette polish):** in the **motion** group, the running-sprite self-state reporters
  (`x position` / `y position` / `velocity x` / `velocity y`) are now grouped at the **end of the group
  behind an `HSeparator`**, so they read as a distinct "this sprite" cluster (`direction` and the
  cross-sprite `x/y position of` stay in the main run). `BlockView.palette_groups` stable-partitions
  them last (`_SELF_STATE_REPORTERS` + `is_self_state_reporter`); `BlockPalette._build` draws the
  separator before the first one (`_add_separator`). Also **left-justified** the *Make a Variable* /
  *Make a Block* button labels (`alignment = HORIZONTAL_ALIGNMENT_LEFT`). Files: `block_view.gd`,
  `block_palette.gd`. Pure editor-side; no opcode / data-shape / runtime change.
  - **F5-verify:** open the editor, look at the MOTION palette group — the four position/velocity
    reporters sit below a thin divider at the bottom of the group; the two Make buttons read left-aligned.
- **Prior shipped:** **`while` block** — a CONTROL C-block that loops *while* a boolean condition holds
  (Scratch's "repeat until" sibling). The usual one-`_OPCODES`-entry + one-interpreter-handler step, no
  block-data-shape change, no editor change: it's a C-block with a `{condition}` boolean slot (`bool_inputs`)
  and a `body`, so the renderer/palette/canvas carry it like `if`/`forever`. `interpreter._on_while` is
  `_on_forever` with a condition re-checked each loop — yields one fixed physics frame per iteration (can't
  freeze the engine) and polls Stage/`_alive` so `stop` unwinds it within a frame. A condition that never
  goes false ≡ `forever`. Files: `block_view.gd` (`C_OPCODES` + the `_OPCODES` entry), `interpreter.gd`.
  - **F5-verify:** a CONTROL `while {condition}` block appears in the palette; e.g. make an `i` variable,
    `when_flag_clicked → set i to 0 → while (i < 5) { change i by 1 → say (i) }` counts 0→5 then stops.
- **Prior shipped:** M42 — **sprite visual order (editor + blocks).** Two halves:
  - **Editor:** four **Layer** buttons (To Front / To Back / Forward / Backward) in the inspector's Stage
    panel reorder the selected sprite within `_scripts` — which **is** the build-time z-order (both
    `StageView._render` and `Stage._add_sprite` walk the array in order). `editor._reorder_selected` does
    an in-place `remove_at`+`insert` (stage view's `_sprites` reference stays valid, pan survives),
    rebuilds the selector in the new order, re-selects the moved sprite without a reload; buttons grey out
    at the ends. Reordering z also reorders the selector (array order is the editor's single ordering).
  - **Blocks:** two new LOOKS opcodes restack at *play* time via the node's `z_index` — `go_to_layer`
    (`go to {front/back} layer`) and `change_layer` (`go {forward/backward} {num} layers`). Interpreter
    handlers delegate to `Stage.set_layer` (z just past the current extreme) / `Stage.change_layer`
    (z_index ± num, clamped). Sprites build at z_index 0 (so editor array order = the initial stack);
    blocks override. One `_OPCODES` entry + one handler each, no editor change (enum + numeric slots).
  - Files: editor half `editor.gd`/`editor.tscn`; blocks half `block_view.gd`, `interpreter.gd`,
    `stage.gd`. *(editor half committed `cdf6993`; blocks half committed/pushed: pending)*
  - **F5-verify (editor):** Stage mode → select the Ball → **To Back** (behind paddles/HUDs), **To
    Front** (over all), **Forward/Backward** nudge one layer; end buttons grey out. RUN/SAVE keep it.
  - **F5-verify (blocks):** a LOOKS group block `when_flag_clicked → go to front layer` on a sprite that
    normally renders behind another → at RUN it draws on top; `go to back layer` / `go forward/backward N
    layers` move it the other ways.
- **Prior shipped:** M41 — **animation blocks** (tween a variable over time). One new statement opcode,
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

- M51 — **keyboard authoring mode.** A keyboard cursor (gap / slot / new) + a fuzzy block picker make the
  block editor fully keyboard-drivable alongside drag/drop; nested reporter expressions build recursively
  via the picker. Editor-only UI state in `block_canvas.gd` (+ `BlockView.opcode_label`/`opcode_template`);
  no opcode / data-shape / runtime change.
- M50 — **category recolours are per-project.** A recolour now rides in the project `.json`
  (`block_colors` key) instead of the global `blocks/block_styles.tres`; it loads with the project, resets
  on NEW, and missing categories draw their default. Editor persistence only.
- M49 — **recolour a block category from its palette header.** Section titles are `ColorPickerButton`s;
  picking recolours the category live and saves `blocks/block_styles.tres`. Editor UI only (`BlockPalette`
  + `BlockView.set_category_color`/`save_styles`); no opcode / data-shape / runtime change.
- M48 — **block rendering via editable `.tscn` shells** (one scene per shape under `blocks/`) +
  `BlockStyles` colour resource. Pure rendering refactor.
- M47 — **collapsable scripts.** Collapse a top-level script in the block canvas to a one-line summary
  bar (header chevron `+`/`-`, or **Cmd/Ctrl+E** on a selection) and expand it again. Editor-only UI state (an
  optional `collapsed` flag per stack in `BlockCanvas._stacks`; never serialized, reset on a sprite
  switch) — no opcode / data-shape / runtime change. A collapsed bar drags / selects / deletes as one
  unit. Files: `block_view.gd` (`build_collapsed_stack`/`_summary_text`/`count_blocks`), `block_canvas.gd`.
- M46 — multi-block selection in the canvas (click / Shift-click / double-click / rubber-band; move /
  delete / duplicate together) + reporters can live free on the canvas.
- M45 — **pixel costume editor.** A third editor mode, **Paint** (beside Blocks and Stage), paints a
  sprite's costume on a pixel grid: pencil / eraser / fill / eyedropper, a palette (recolour the active
  swatch live), clear-all. The costume is one optional `costume` key on the sprite dict —
  `{cw, ch, palette: ["#rrggbb"…], pixels: [indices, −1 = transparent]}` — mutated in place
  (data-is-canonical) and round-tripped through SAVE/RUN; an unpainted sprite / pre-M45 save **falls
  back to the flat `color`** (no `costume` key). Runtime ([`Stage._make_costume_texture`](scripts/stage.gd))
  builds the texture from the index grid, drawn **no-stretch** at native `cw×ch` (1 costume px = 1 stage
  px, `TEXTURE_FILTER_NEAREST`); painting sets the sprite's `w/h` to `cw/ch` so collision/inspector/stage
  preview agree (the stage resize handle + inspector w/h are disabled for a painted sprite). New file
  [`scripts/paint_view.gd`](scripts/paint_view.gd) (mirrors `stage_view.gd`); `editor.gd`'s `_stage_mode`
  bool widened to `enum Mode {BLOCKS, STAGE, PAINT}` + `_set_mode`. **No opcode, no block-data-shape
  change.** Deferred: multiple costumes / switching blocks, animation frames, undo, PNG import, shared
  palette, resize-canvas. *(code complete, uncommitted)*
  - **M45 refinement (uncommitted):** the default costume palette is now the **16-colour PICO-8
    palette** (canonical index order), and the Paint view has **zoom** — a `− [px] +` row in the tools
    panel and **Ctrl+wheel** over the grid. The grid now lives in a `ScrollContainer` (shrink-centred,
    so a zoomed-in costume can be panned to its edges; centred when smaller than the viewport). Zoom is
    a multiplier on the fit-to-`_VIEW_BOX` base cell size (`_recompute_scale`), clamped `[0.5, 12]`,
    persisting across selection/costume changes. All in [`scripts/paint_view.gd`](scripts/paint_view.gd).
  - **M45 zoom bugfixes:** (1) Ctrl+wheel zoom required the cursor to be *exactly over a costume pixel*
    (`_cell_at(...).x >= 0`), so wheeling over the blank margin around a shrink-centred costume silently
    did nothing — and zoom-OUT got stuck right at the point the grid first fits the viewport (it
    re-centres and the cursor lands on the new margin). Now it tests the whole `_grid_scroll` viewport
    rect, so a wheel anywhere over the grid area zooms. (2) The wheel modifier now accepts **Cmd (meta)
    as well as Ctrl**, because macOS reserves Ctrl+scroll for system screen-zoom (so a Ctrl+wheel event
    never reaches Godot on a Mac — Cmd+wheel is the working modifier there).
- M44 — **lists (ordered collections), the structural twin of variables.** A list is a named `Array`
  with global / per-sprite-local scope, made / renamed / deleted from the palette's new **LISTS** group
  exactly like a variable. **Nine opcodes** (the full Scratch set): statements `list_add` /
  `list_delete` / `list_delete_all` / `list_insert` / `list_replace`, reporters `list_item` /
  `list_item_index` / `list_length` / `list_contains?` (boolean). `{list}` is a data-scoped dropdown
  (new `"lists"` `data_enums` source → `BlockView.project_lists`); `{index}` is 1-based (also accepts
  typed `"last"`/`"random"`); out-of-range is ignored / yields `""`. Runtime stores lists local-first-
  then-global on `Target.lists` / `Stage._lists` (`get_list`/`has_list`), seeded deep-copied in
  `Stage._ready`, mutated **in place**; clones inherit a deep copy. Model is `PongScripts.lists()`
  (stock `[]` — unexercised by Pong, like clones) → editor-owned `_lists`, persisted under a new `lists`
  JSON key (absent ⇒ `[]`, pre-M44 saves still open). Editor / palette / cascade
  (`count`/`rewrite`/`strip_list_refs`, `rename_list`/`delete_list_refs`) are near-verbatim copies of the
  variable code (M20/M21); sprite rename/delete carry local lists like local variables (M25). Three new
  dialogs in `editor.tscn`. **No block-data-shape change.** Deferred: an on-stage list monitor widget,
  an index dropdown, a `for each` loop. **Data-only** this milestone (read via reporters).
- M43 — **cross-sprite position reporters + built-in velocity.** *(1)* `x position of {name}` /
  `y position of {name}` (`x_position_of` / `y_position_of`, motion reporters, sprites dropdown) read
  another sprite's centre through the registry — retiring the demo's `left_paddle_y` / `right_paddle_y`
  **relay globals** (the ball now reads `y position of (paddle)` directly in `_paddle_bounce_dir`).
  Added to `_SPRITE_OPCODES` so the M25 sprite rename/delete cascade covers them. *(2)* **Velocity is
  built-in**: `Target.velocity: Vector2` (px/tick), applied by `Stage._physics_process`
  (`node.position += velocity`) to a `_movables` list (registered sprites + clones), with blocks
  `set_velocity` / `change_velocity` (statements) + `velocity_x` / `velocity_y` (reporters). Zero
  velocity is a no-op, so existing projects are unchanged. *Demo:* the CPU right paddle was rewritten
  from M41's `animate` sweep to velocity-driven (flips sign + snaps at the rail ends). No
  block-data-shape change, no editor change. (`target.gd`, `stage.gd`, `interpreter.gd`,
  `block_view.gd`, `pong_scripts.gd`) *(committed/pushed: pending)*
- M42 — **sprite visual order (editor + blocks).** *Editor half:* four Layer buttons (To Front / To Back
  / Forward / Backward) in the stage inspector reorder the selected sprite within `_scripts` (= the
  build-time z-order, since both `StageView._render` and `Stage._add_sprite` walk the array in order) —
  in-place `remove_at`+`insert`, selector rebuilt + re-selected without a reload, buttons disable at the
  ends; no opcode/data-shape/runtime change (`editor.gd`+`editor.tscn`, `cdf6993`). *Blocks half:* two new
  LOOKS opcodes `go_to_layer` / `change_layer` restack at play time via node `z_index` (`Stage.set_layer`
  / `change_layer`); one `_OPCODES` entry + one handler each, no editor change (`block_view.gd`,
  `interpreter.gd`, `stage.gd`). *(blocks half committed/pushed: pending)*

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
