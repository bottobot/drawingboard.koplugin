# Drawingboard for KOReader — Kobo stylus fork

A full-screen sketchbook for KOReader, with pressure-aware Kobo pen input, finger-drawing controls, three layers, editable projects, and PNG export.

This is **[bottobot's fork](https://github.com/bottobot/drawingboard.koplugin) of [eznas/drawingboard.koplugin](https://github.com/eznas/drawingboard.koplugin)**. The drawing engine, tools, and original interface are upstream work by eznas. This fork adds Kobo stylus integration and an English interface; it is independently maintained and is not an official KOReader or Kobo product.

**Install the [`kobo-stylus` branch](https://github.com/bottobot/drawingboard.koplugin/tree/kobo-stylus) for the fork's features.** The `main` branch is retained at the upstream v63 baseline; downloading that branch or an upstream release does not include the Kobo changes. The retained `v63` tag and About version identify the upstream base, not a separately tested fork release.

This is a development branch. A dated, reproducible physical-device acceptance record is not yet included in this repository. See [testing and release checks](docs/TESTING.md) before treating a build as a verified release.

## What the fork changes

| Area | Behaviour in `kobo-stylus` |
| --- | --- |
| Pen input | Routes supported KOReader stylus events into the existing brush, shape, fill, text, and selection tools. |
| Pressure | On by default for freehand brush strokes. Where pressure events are available, width ranges from 30% to 100% of the selected stroke width. |
| Pen erasing | A contact reported by KOReader as an eraser uses the existing object eraser for that contact. Hold the side button **before touching down** if the device maps it to the eraser tool. |
| Finger drawing | `auto` initially permits fingers, then disables canvas finger gestures after the first pen event, including hover, until the board is reopened. `on` and `off` are explicit alternatives. |
| Palm filtering | Canvas finger gestures are blocked during an owned pen contact and for 600 ms after pen activity, including when finger drawing is `on`. Toolbar and dialog controls remain accessible. |
| E-ink updates | Live brush strokes use a clipped dirty region and the `fast` waveform, followed by a regional `ui` refresh on pen-up. |
| PNG location | **Options → Export folder** selects a default PNG destination. Editable projects retain their separate default location. |
| Language | Removes the upstream Chinese dictionary, language selection, and Chinese README; translates source comments. Shared KOReader dialogs may still follow KOReader's own language. |
| Metadata | Removes the deprecated `name` field from `_meta.lua`. |

Implementation details, commit provenance, and branch policy are in [Fork history and maintenance](docs/FORK.md).

## Drawing tools

The upstream toolkit is retained:

- Freehand strokes and seven brush-tip shapes: ellipse, square, triangle, inverted triangle, diamond, slash, and backslash.
- Lines, rectangles, ellipses, filled shapes, path fill, and enclosed-area fill.
- Grayscale, width, opacity, blend modes, and per-stroke randomisation controls.
- Text, object erasing, and selection with move, copy, scale, and rotation.
- Three layers with visibility and opacity controls; undo and redo per layer.
- Editable `.drawing` project files and full-canvas PNG export.

The canvas and exported art are grayscale, including on a colour e-reader. The eraser removes objects or strokes; it is not a pixel eraser.

![Drawingboard interface inherited from upstream](docs/screenshot.png)

*This screenshot is inherited from upstream. It illustrates the drawing interface, not a validation of this fork on a Kobo.*

## Compatibility and support status

| Environment | What is known |
| --- | --- |
| Kobo Libra Colour with Kobo Stylus 2 | The stated development target in the stylus implementation. Physical acceptance of the current branch is still to be recorded. |
| KOReader input API | Pen features require both `Device.input:registerStylusCallback` and `:unregisterStylusCallback`, with the event behaviour described in [FORK.md](docs/FORK.md). Both APIs were present in the inspected v2026.07.1 runtime. The original implementation names 2026.07 or newer as its target; the code checks the API rather than a version string. |
| KOReader without that API | The plugin skips stylus registration and leaves pen handling to KOReader's existing finger/gesture path. Pressure and the fork's palm filtering are unavailable through that fallback. The device must already provide usable input. |
| Kindle | The upstream README reports Kindle development/testing. That does not establish regression testing of this fork on a Kindle. |
| Other Kobo models, pens, or platforms | Not certified here. A compatible event API alone does not establish digitizer support, button mapping, pressure range, rotation accuracy, or refresh quality. |

Installing this plugin cannot add stylus hardware support to an e-reader that lacks it. Pressure is optional: absent pressure events, brush strokes use normal width. A highlighter tool event currently behaves like the pen; it has no separate highlighting action.

## Installation

Install into an existing, working KOReader installation. Save your work and fully exit KOReader before replacing plugin files.

### Download the fork branch

1. Download the [Kobo branch ZIP](https://github.com/bottobot/drawingboard.koplugin/archive/refs/heads/kobo-stylus.zip).
2. Extract it on your computer. Rename the extracted top-level folder to **`drawingboard.koplugin`**.
3. Copy that folder into KOReader's `plugins/` directory. A typical Kobo installation uses `.adds/koreader/plugins/` on user-visible storage; use the location of your actual installation.
4. Confirm that `main.lua` is directly inside `plugins/drawingboard.koplugin/`, without an extra ZIP wrapper directory:

   ```text
   koreader/
   └── plugins/
       └── drawingboard.koplugin/
           ├── main.lua
           ├── _meta.lua
           ├── LICENSE
           └── drawingpad/
               ├── drawing_canvas.lua
               ├── stylus.lua
               └── icons/
   ```

5. Restart KOReader, enable Drawing Board in plugin management if necessary, and open **Drawing Board** from its tools menu.

### Clone the fork branch

For a development checkout, run this from the desired parent directory on your computer, then copy the resulting folder as above:

```sh
git clone --branch kobo-stylus --single-branch \
  https://github.com/bottobot/drawingboard.koplugin.git drawingboard.koplugin
```

The `drawingpad/test/` directory and demonstration media in `docs/` are not required at runtime. Preserve the license and fork documentation when distributing a copy. There is no plugin dependency download or build step.

## First drawing and pen controls

1. Open **Drawing Board**, choose **Brush** in the tools panel, and set width and grayscale in **Options**.
2. Draw a short stroke. With the required pen API, try light and firm pressure. Turn **Pressure sensitivity** off for a fixed-width stroke.
3. For temporary erasing, lift the pen, hold its eraser-mapped button, then touch down and erase. Lift again to return to the selected tool. Changing the button halfway through a contact does not change the tool for that contact.
4. Tap **Finger drawing** to cycle `auto → on → off → auto`. If `auto (off)` appears, pen activity has disabled canvas finger input for this board session. Choose `on` to use fingers again, or close and reopen the board to reset automatic detection.
5. Use the function panel's **Save** for an editable project and **Export** for a PNG. Enter the filename without its extension; the dialog appends it.

Keep the pen away from the screen briefly before trying a canvas finger gesture: hover can renew the 600 ms palm-filtering window. Choosing `off` also suppresses canvas gestures such as pinch and two-finger gestures. Toolbar and dialog controls still respond to fingers.

## Saving, opening, and data locations

| Data | Default location and behaviour |
| --- | --- |
| Editable projects | `drawingboard/` under KOReader's data directory, with a `.drawing` extension. Saves layer contents, active layer, layer visibility, and layer opacity. Loading clears undo/redo history. |
| PNG exports | The same directory by default. **Options → Export folder** changes the PNG default; an explicit folder selected in the save dialog takes precedence. Hidden layers are not exported. |
| Tool preferences | `drawingpad_settings.lua` in the plugin directory; an `.old` backup may also exist. Includes pen options, destinations, font settings, and last entered text. Saved when closing the board; choosing an export folder also saves settings. |
| Diagnostics | `drawingboard.log` in the plugin directory if `LOG_ENABLED` is enabled. Stylus warnings/debug messages use KOReader's logger separately. |

`koreader/drawingboard/` is shorthand for KOReader's data-directory location; some installations separate program and data directories. Choosing an export folder does not move existing files. File dialogs share a remembered explicit folder, so inspect the displayed destination before saving.

**Save before opening another project or exiting.** There is no automatic project recovery. Opening a project replaces the current canvas and clears undo/redo; the Open path currently does not prompt to save the drawing it replaces. A PNG is flattened and cannot restore editable objects through the project's Open command.

**Only open `.drawing` files you created or trust.** The current format is Lua source, and the loader executes it with KOReader's privileges. It is not a safe interchange format for untrusted downloads. Prefer PNG when sharing artwork until the loader uses a data-only parser. See [release blockers](docs/TESTING.md#known-release-blockers).

## Upgrade, rollback, and removal

- **Upgrade:** save and close the board, exit KOReader, and back up the existing plugin folder plus every project/export folder you use. Preserve `drawingpad_settings.lua` and its `.old` file for preferences. Replace the plugin with one complete branch snapshot, restore those preferences, and restart KOReader. Check a saved project and a PNG export before resuming normal use.
- **Rollback:** exit KOReader and restore the complete previous plugin folder. Keep artwork backups separately; project compatibility across branches is not guaranteed by the shared extension.
- **Remove:** save your work, exit KOReader, and remove or move `drawingboard.koplugin` out of `plugins/`. Projects/images outside it remain in their destinations. Back up preferences/logs inside the plugin before removing it if needed.

Do not leave multiple active copies with different folder names in `plugins/`; they use the same module and menu names.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Drawing Board does not appear | Verify the exact `drawingboard.koplugin/main.lua` layout, plugin enablement, and a full KOReader restart. Check KOReader's log for a load error. |
| No pressure or special pen handling | Confirm `kobo-stylus` is installed and `drawingpad/stylus.lua` exists. Check the KOReader build for both callback APIs; fallback input lacks these fork features. |
| Fingers no longer draw | Inspect **Finger drawing**. `auto (off)` is expected after a pen event. Choose `on` and move the pen away from the display. |
| Side-button erasing does not work | Press before pen-down. The device/KOReader must report an eraser tool; the fork does not remap raw physical buttons. |
| Pen coordinates are displaced or rotated | Record the device, KOReader build, orientation, and minimal reproduction. Try a fresh board after changing orientation. Rotation needs physical validation for each device. |
| Export says the canvas is empty despite visible content | The PNG entry point currently checks the active layer. Select a layer containing content before exporting; this is a known issue. |
| Export goes to an unexpected folder | An explicit save-dialog folder overrides the PNG default. Reselect **Export folder** to clear that override, then inspect the destination. |
| Save fails or a project will not reopen | Check free storage and permissions, retain the original, and use another filename. A successful save message is not yet a full project integrity check. |
| Ghosting after drawing | Use the board's refresh control. Appearance and latency depend on the device and need physical testing. |

Use [this fork's issue tracker](https://github.com/bottobot/drawingboard.koplugin/issues) for fork issues. Include branch/commit, KOReader build, device/pen model, orientation, settings, expected behaviour, and reproduction steps. Inspect and redact logs/settings before attaching them: they can contain paths and entered text. Do not post complete KOReader settings or personal projects by default.

## Development and testing

[TESTING.md](docs/TESTING.md) covers dependencies, commands, missing stylus coverage, physical acceptance, and release blockers. In an isolated KOReader v2026.07.1 runtime on 2026-10-11, **all 20 existing test scripts passed** after correcting an inherited stale brush-tip menu assertion. The feature test explicitly skipped grey-menu assertions that could not run headlessly; pen hardware remains unvalidated. Tests require KOReader's LuaJIT, `setupkoenv`, frontend modules, and native libraries; **plain standalone `lua` is insufficient**.

For the source map, upstream comparison, and contribution workflow, see [FORK.md](docs/FORK.md).

## Attribution and license

Distributed under the [GNU Affero General Public License, version 3](LICENSE), retaining the upstream license. Original Drawingboard work is by [eznas](https://github.com/eznas/drawingboard.koplugin); fork changes are maintained in [bottobot/drawingboard.koplugin](https://github.com/bottobot/drawingboard.koplugin).

**Notice of modification:** this version was modified on 2026-10-04 for translated comments, English UI, Kobo stylus input, and plugin metadata. Documentation and an inherited brush-tip menu test assertion were updated on 2026-10-11. See [NOTICE](NOTICE) and [commit history](docs/FORK.md#provenance).

The `drawingpad/icons/appbar.menu.svg` and `drawingpad/icons/cre.render.reload.svg` icons come from KOReader's official icon set under AGPL-3.0, as credited by upstream. Other icons and demonstration assets are retained from upstream. No separate artwork license or creator record is supplied here beyond the upstream material; preserve attribution when redistributing it.
