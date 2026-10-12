# Testing and release checks

This page distinguishes successful test-script results from complete coverage,
and emulator results from physical e-ink acceptance. All 21 regression scripts
now pass, with an explicit headless UI skip; no physical-device
certification is claimed.

## Recorded status

The 2026-10-11 review inspected `kobo-stylus` at
`87219fa1e34e989596f4caf03595fecad95e83dc` and upstream v63 (`46a438b`). The
documentation pass statically checked provenance, installation, runtime entry
points, persistence, and dependencies. An independent validation pass ran the
existing tests and bounded persistence fixtures inside an isolated runtime,
then reran the affected feature test after the assertion-only correction
described below. Those initial results preceded the project-storage fixes below. Neither pass
changed an attached device. There is no stylus-specific regression test or dated
physical acceptance record.

| Check | Actual result |
| --- | --- |
| Native runtime | KOReader runtime's `git-rev` reports `v2026.07.1`; bundled LuaJIT, SDL dummy video, software renderer, 1264 × 1680, 300 DPI, portrait. |
| Existing regressions | Initial run: 19 of 20 `*_test.lua` scripts exited successfully. After the assertion-only correction, the affected script was rerun successfully: **20 of 20 scripts pass in aggregate**. Unchanged passing scripts were not rerun. |
| Initial failure | `feature_test.lua` passed nine reported sections, then failed the brush-tip menu assertion at line 786: expected at least 8 callbacks (7 tips plus cancel), observed 7. |
| Corrected feature test | Changed the inherited expectation to exactly seven tip buttons. Under the same isolated runtime, it exited successfully with `ALL FEATURE TESTS PASSED` and 17 passing sections, including the previously unreached sections. |
| Headless UI gap | The feature test reported `WARN: grey menu could not be constructed headless, skipping assertions`. Those grey-menu UI assertions remain unvalidated. |
| Selected passing scripts | `project_test.lua`: 2/2 sections; `adversarial_test.lua`: 33 passed, 0 failed; `stability_test.lua`: all reported checks passed. |
| Project execution fixture | Opening a dummy `.drawing` created its deliberately requested marker inside scratch, confirming source execution before data validation. |
| Project I/O fixtures | With file handles that returned `nil, error` from `write` or `close`, `_doSaveProject` still returned `true`. Each fixture made one write and one close call. |

Source comparison explains the brush-tip failure: the menu removed its cancel
button in upstream v62t and closes on an outside tap, but the inherited v63
test still expected seven tip buttons plus cancel. All seven tip definitions
remain present. The test was corrected to expect exactly seven buttons; no
production menu or drawing code changed. The rerun reached and passed the later
sections, subject to the grey-menu skip listed above.
The persistence fixtures used dummy data and scratch-only effects. No real
projects or live device state were used.

Each test ran separately, from the KOReader runtime directory, using its
`./luajit` with the absolute path to the test script. A fresh `KO_HOME` under
scratch isolated each script. The test environment was explicitly populated:

```text
KO_HOME=/scratch/<test-name>
SDL_VIDEODRIVER=dummy
SDL_VIDEO_DRIVER=dummy
SDL_RENDER_DRIVER=software
EMULATE_READER_W=1264
EMULATE_READER_H=1680
EMULATE_READER_DPI=300
EMULATE_READER_FORCE_PORTRAIT=1
```

The launcher started from an empty environment with safe values for `HOME`,
`TMPDIR`, `PATH`, `LANG`, `PYTHONDONTWRITEBYTECODE`, and `XDG_CACHE_HOME`. Bubblewrap
unshared namespaces and disabled nested user namespaces; source/toolchain were
read-only, external network was unavailable, and the only writable storage was
a 512 MiB scratch tmpfs, also used for `/tmp`. Limits were 120 CPU seconds,
3 GiB address space, 256 open files, 128 MiB per file, 64 processes, 180 seconds
wall time for the sandbox, and 20 seconds per test subprocess. These describe
the performed run; the example commands below still require an equivalent
isolated environment.

## Project storage fixes

On 2026-10-11, the Kobo fork replaced project-file execution with a literal-data
parser and checked atomic saves. A fresh isolated run executed all **21**
`*_test.lua` scripts successfully against the changed source. The existing
project test still passes both roundtrip/corrupt-file sections; the new
`project_safety_test.lua` passes **15** sections. The grey-menu assertion block
still skips in the headless feature test. Pen/device acceptance remains open.

The regressions cover legacy literals and escaped strings, retained pressure
values, rejection of code/functions/expressions/trailing statements, parser
limits and invalid element schemas, preservation of canvas/visibility/undo on
rejected imports, successful project readback, failure propagation into the save
UI, and preservation of an existing file after injected open, write, close,
short-write, and rename failures. Both ordinary `nil, error` returns and thrown
write/close failures are exercised. Temporary paths are cleaned after success
and failure; a pre-existing temporary path is neither used nor removed.

The parser accepts only upstream-generated literal data; it never calls
`loadfile`, `loadstring`, or a project-supplied function. Files over 8 MiB,
nesting beyond 16 table levels, more than 500,000 entries, invalid layers,
unknown element kinds, and unsupported geometry are rejected before current
state is changed. Limits include 10,000 elements overall, 32,768-pixel coordinate
magnitudes, 800-pixel stroke/font sizes, and bounded text/points/fill spans.
The text extent is prepared before import to bound native buffer allocations.
These are import limits, not a claim that every possible malformed input or
renderer behavior has been exhaustively tested.

The writer uses an atomically acquired sibling directory and a complete
`project.tmp`; it checks the write return, close return, and byte count before
renaming it to the requested destination. It preserves the old destination on
failure. This does not add an `fsync`/power-loss durability guarantee. A process
crash can leave a `.saving-*` directory with recoverable temporary data.
The on-disk format remains compatible with the literal files produced by
upstream v62/v63; files using arbitrary Lua or manual expressions are rejected.

The fresh run used the same pinned native runtime and OS sandbox limits
described above, with a 45-second timeout for each test subprocess, exposing
only read-only plugin/runtime/toolchain paths and scratch data.
No actual Kobo, user settings, live filesystem fault, or network was exercised.

## Runtime and test dependencies

The scripts in `drawingpad/test/` require a complete compatible KOReader runtime:

- KOReader's LuaJIT binary and `setupkoenv.lua`.
- Frontend modules, fonts/resources, and native libraries, including
  `ffi/blitbuffer` and `libs/libkoreader-lfs`.
- The emulator backend for that build, with disposable settings and outputs.

Plain `lua drawingpad/test/feature_test.lua` from this repository does not
provide these dependencies. Syntax parsing alone does not verify integration.

Tests open KOReader settings, allocate native buffers, and some write fixed
filenames under `/tmp`. Run them one at a time in an isolated disposable
runtime with no device mount or personal profile exposed. For review of
unfamiliar source, use an OS sandbox with no external network, an empty
environment with an explicit safe allowlist, read-only source/toolchain,
scratch-only writes, and bounded CPU, memory, process, file-size, disk, and
wall-clock use. Map `/tmp` into scratch. Do not fetch/install test dependencies.

## Representative regression commands

These commands run **inside an already isolated KOReader runtime**, with the
plugin at `plugins/drawingboard.koplugin/` and the current directory containing
`setupkoenv.lua` and `luajit`:

```sh
./luajit plugins/drawingboard.koplugin/drawingpad/test/feature_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/project_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/project_safety_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/alpha_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/blend_mode_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/layer_zorder_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/stroke_start_refresh_test.lua
./luajit plugins/drawingboard.koplugin/drawingpad/test/adversarial_test.lua
```

Other scripts cover fill transforms, visibility, repaint regions, sliders,
panels, and stability. Files named `*_bench.lua` are benchmarks, not substitutes
for assertions. Read each script's setup/output behaviour before automating
it. If a test catches and prints errors, assess output as well as exit status.

Record the full plugin commit, KOReader revision/build, platform, commands,
sandbox/environment details, exit statuses, failures, and elapsed time. Use
dummy projects. Do not publish personal settings or unredacted logs.

## Missing fork-specific regressions

| Area | Required cases |
| --- | --- |
| Callback lifecycle | Missing API; repeated attach/detach; prior callback restoration; another component replacing the hook; exceptions; close/reopen; suspend with a live stroke. |
| Contacts | Down/move/up; hover; malformed coordinates; lifted slot reporting finger; multiple slots; toolbar/dialog contacts; button state chosen at down. |
| Pressure | No pressure stream; min/max/clamping; every brush tip; pressure factors survive save/load and redraw. |
| Finger filtering | `auto` enabled then disabled by hover/contact; reopen resets it; `on` respects palm window; `off` blocks canvas gestures while controls work. |
| Geometry/refresh | Every supported rotation; edges and toolbar crossings; clipped dirty regions; final refresh; no input/refresh state left after close. |
| Storage | Preferences survive reopening; explicit folder overrides PNG default; export folder does not alter project default; visible-layer combinations; failed writes reported. |

Mocks verify ownership/state transitions, not digitizer behaviour, waveforms,
palm handling, or physical sleep/wake.

## Physical acceptance checklist

Use a backed-up device and dummy artwork. Record device/pen model, firmware,
KOReader build, plugin commit, date, tester, and actual results.

1. Install the proposed archive and verify menu discovery and initial input.
2. Test dots and strokes, every tip, pressure on/off, layers, opacity,
   undo/redo, shapes, fills, selection, text, and erasing, with pen and finger.
3. Test every supported orientation and screen edge, toolbar/dialog input,
   hover, palm contact, and all finger modes.
4. Export PNG and save/reopen a project. Inspect layers and pressure widths
   after reopening; verify destinations and filenames on storage.
5. Close the board and confirm reader gestures still work. Reopen it,
   sleep/wake with the canvas visible, then draw and save again.
6. Record ghosting, flashes, latency, and longer-session behaviour. Use only
   non-personal screenshots/photos.
7. Test upgrade and rollback with a retained prior copy and dummy project.
   Confirm removal preserves artwork stored outside the plugin.

Mark untested rows explicitly. Do not infer another model's result from a
similar device or an emulator.

## Known release blockers

Project execution and unchecked project writes are fixed as recorded above.
The following remaining observations were identified during the earlier review
and have not been addressed by the storage patch. This is not a comprehensive
security audit.

| Issue | Source and consequence | Acceptance for a fix |
| --- | --- | --- |
| Opening replaces unsaved work | `_openProject` calls `_loadProject` without a save confirmation; loading clears layers and undo state. | Prompt before replacing dirty content and validate into temporary state. Cancelled/invalid opens must preserve the drawing. |
| Export checks only the active layer | `_save` rejects `#self.elements == 0`, although export renders the visible canvas. Other visible layers can contain art. | Check all visible layers; test blank active layer plus content elsewhere. |
| Pen validation is absent | No direct `stylus.lua` regression coverage or physical acceptance record in this revision. | Add lifecycle/pressure/palm tests and an accurate device/build acceptance matrix. |
| Some UI assertions are skipped headlessly | `feature_test.lua` reports that grey-menu construction failed headlessly and skips the corresponding assertions, despite the script's successful exit. | Validate the menu in a suitable emulator/display session or on the acceptance device and record the result. |

## Packaging a fork release

- Select a distinct fork version/tag; preserve inherited upstream tags.
- Package the tested commit in one `drawingboard.koplugin/` root with
  `main.lua`, `_meta.lua`, runtime modules/icons, `LICENSE`, `NOTICE`, and docs.
- Exclude real settings/backups, logs, artwork, emulator state, credentials,
  `.git/`, and test output. Upstream demos are optional; review provenance
  before redistributing them as release media.
- Install that exact archive into the disposable runtime and acceptance device.
  A tested checkout does not prove correct archive layout or contents.
- Publish its SHA-256, upstream base, fork commit, runtime requirements, changes,
  limitations, and actual validation results.
- Ensure the landing page/default branch leads to the fork instructions, and
  verify download links resolve to the intended build.

Until these checks pass, describe this as a development fork with documented
limits rather than a hardware-certified release.
