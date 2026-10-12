# Fork history and maintenance

This document describes the `kobo-stylus` branch of
[bottobot/drawingboard.koplugin](https://github.com/bottobot/drawingboard.koplugin).
The upstream project is
[eznas/drawingboard.koplugin](https://github.com/eznas/drawingboard.koplugin).

## Purpose and ownership

Upstream supplies the drawing canvas, renderer, tools, persistence, and e-ink UI.
The fork integrates Kobo pen events with those tools and presents its own UI in
English. It retains upstream author attribution, license, and Git ancestry.
Report fork-specific input, pressure, palm-filtering, or installation problems
to the fork. Before filing an upstream issue, reproduce it on an unmodified
upstream revision; a fork-only failure is not evidence of an upstream bug.

## Branches and versions

The reviewed local refs on 2026-10-11 were:

| Ref | Revision | Role |
| --- | --- | --- |
| `main` / local `origin/main` | `46a438bfaa222f365ec08ff3b3812fd0518ca4ae` | Upstream v63 baseline; local `origin/HEAD` points here. |
| `v63` | `46a438bfaa222f365ec08ff3b3812fd0518ca4ae` | Inherited upstream tag. |
| `kobo-stylus` / local `origin/kobo-stylus` | `87219fa` | Four fork commits on top of that baseline, before this documentation revision. |

These are revision records from before the documentation publication, not a
claim that upstream has stopped developing or that remote refs stay unchanged.
The maintained fork and its documentation live on `kobo-stylus`; `main` remains
the inherited baseline. Always use the explicit branch in installation commands
so that a repository-default change cannot select a different implementation.

About still reports upstream `v63` and `eznas`, with a Kobo-fork notice.
Identify a fork build by branch **and full commit hash**, not `v63` alone.
A future fork release should use a distinct version/tag and record its upstream
base and validation. Do not repoint inherited tags.

## Provenance

All four implementation commits are dated 2026-10-04:

| Commit | Change |
| --- | --- |
| [`23a2fce`](https://github.com/bottobot/drawingboard.koplugin/commit/23a2fce) | Translates Chinese comments into English; the commit describes no code changes. |
| [`f51e438`](https://github.com/bottobot/drawingboard.koplugin/commit/f51e438) | Removes Chinese UI dictionary/automatic language selection and `README_zh.md`; keeps identity helpers so call sites remain recognisable. |
| [`fa10ad1`](https://github.com/bottobot/drawingboard.koplugin/commit/fa10ad1) | Stylus routing, pressure, finger filtering, refresh hooks, PNG destination setting, initial fork notice. |
| [`87219fa`](https://github.com/bottobot/drawingboard.koplugin/commit/87219fa) | Removes deprecated `_meta.lua` `name` metadata. |

The 2026-10-11 maintenance work clarifies these changes and limits and corrects
an inherited regression-test assertion: the brush-tip menu has seven tip buttons
and dismisses on an outside tap, whereas the test still counted a removed cancel
button. The test correction changed no production behaviour. Subsequent maintenance
on the same date adds a bounded, non-executing project parser and checked,
atomic project saves. These fixes retain the upstream literal file format
and license. They do not establish physical-device acceptance or stylus coverage.

## Code map

| File | Responsibility |
| --- | --- |
| `main.lua`, `_meta.lua` | Menu entry and metadata. |
| `drawingpad/drawing_canvas.lua` | Setup, state, painting, mixin composition, installation of the finger filter. |
| `drawingpad/stylus.lua` | Callback ownership, contact state machine, coordinates, pressure capture, palm filtering, clipped repaint, pen preferences. |
| `drawingpad/strokes.lua` | Shared freehand pipeline, optional point-width factor, refresh hooks. |
| `drawingpad/shapes.lua` | Rendering, including pressure-derived point widths. |
| `drawingpad/const.lua` | Pressure limits, palm window, refresh parameters, persisted setting names, inherited version/author. |
| `drawingpad/actions.lua` | Undo/redo, PNG export, prepared project loading, preferences, close cleanup. |
| `drawingpad/projectfile.lua` | Literal-data parser, bounds/schema checks, checked atomic project-file writing. |
| `drawingpad/menus.lua` | Tool/property/function panels and folder navigation. |
| `drawingpad/i18n.lua` | English identity helpers replacing the translation dictionary. |
| `drawingpad/test/` | Inherited rendering/UI/project regression scripts and benchmarks. |

Translated comments account for much of the full diff. Review behavioural
commits separately before reading the entire baseline comparison:

```sh
git log --reverse --oneline 46a438b..kobo-stylus
git show --stat f51e438
git show --stat fa10ad1
git diff 46a438b..kobo-stylus -- drawingpad/stylus.lua \
  drawingpad/strokes.lua drawingpad/shapes.lua drawingpad/actions.lua
```

## Input contract and limits

The module feature-detects `registerStylusCallback` and
`unregisterStylusCallback` on `Device.input`. It expects slot fields `slot`,
`id`, `x`, `y`, and `tool`; nonnegative IDs indicate contact, and tool
constants distinguish pen, eraser, and highlighter. Coordinates pass through
the gesture detector's rotation mapping, with a screen-rotation fallback.
Validate these assumptions against the actual KOReader build and device.

The local v2026.07.1 runtime inspected during this review contains both callback
APIs and the described slot contract in `frontend/device/input.lua`. This is
source confirmation of the API, not physical pen-input acceptance.

While the board is open, the module chains `eventAdjustHook` to record pressure.
It normalises against a running maximum starting at 4095, clamps the result,
and maps it to 0.30–1.00 of the chosen width. This is a heuristic, not calibrated
force measurement. Whether a contact uses pressure is decided at pen-down;
the pressure factor is then sampled again on every move, so width can vary
within that stroke. Unavailable pressure leaves ordinary width.

The eraser tool is chosen at pen-down. A mid-contact button change is not
reinterpreted. Other tools receive synthetic tap/pan/release gestures; the
highlighter event follows the pen path. Contacts beginning on toolbar/dialog
controls are left to gesture handling for their duration.

On close, the previous stylus callback is restored if the board still owns it.
The pressure hook is restored when possible; if another component has chained
over it, the disabled wrapper is left as a pass-through. The module does not
multiplex another plugin's callback while it owns input. Concurrent pen
integrations therefore need testing.

On suspend, the module finishes an active owned contact and resets contact
state. No physical sleep/wake acceptance is recorded here; exception guards
alone do not prove lifecycle correctness.

## Contributions and upstream syncs

Keep behavioural changes separate from broad translation/formatting edits.
Describe affected tools, settings, input lifecycle, and file compatibility.
Add meaningful regression checks and state which emulator/device checks were
actually performed. Follow [TESTING.md](TESTING.md).

Before a sync, back up projects outside the checkout, start with a clean tree,
record the fork revision, and fetch/inspect the intended upstream revision.
Local `main` is a pinned baseline until deliberately updated, not a live view
of upstream. Review conflicts around input hooks, mixin composition, settings,
serialization, and pressure rendering. Run inherited regressions and input
tests before publishing the integration.

Preserve license notices and add dated modification notices. Exclude real
drawings, settings, logs, personal paths, emulator state, and credentials from
patches/releases. Verify provenance before adding or separately promoting media.
