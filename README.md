# nextclick

Keyboard clicking for macOS: press a key, every clickable thing gets a small label, type the label to click it. A Homerow/Vimac-style tool, built as a Swift library.

## Motivation

Keyboard navigation should work across apps without a subscription. Nextclick adds labels to clickable controls and lets you choose them from the keyboard. Scans run on demand, with no background polling.

## Requirements and integration

macOS 14 or later and Swift 6 or later for the tests. This package is a library, not a standalone app. The private hkd host is optional; an AppKit host can use the public API below. Keep the instance alive, run its methods and command closures on the main thread, and call `stop()` before shutdown. The host needs Accessibility permission and a running AppKit event loop.

```swift
import NextClick

let nextclick = NextClickCommands()
nextclick.start()
nextclick.commands["click.show"]?()
// During host shutdown:
nextclick.stop()
```

## Commands

| Command | Action |
|---|---|
| `click.show` | Toggle labels on the focused window, or on the open menu (Mission Control thumbnails if it's open) |
| `click.system` | Toggle labels on the app's menu bar, status items and the Dock. While `click.show` is up, this switches over |
| `click.search` | Toggle text search: type to filter targets by their text, Tab/↑/↓ to move, Return to click |
| `click.prefetch` | Scan the focused window in the background; a `click.show` within 1.5 s uses the result. Bind it to Caps down so the scan overlaps the key press |
| `click.repeat` | Click the last thing you clicked in this app again, without showing labels |
| `scroll.show` | Toggle scroll mode on the largest scroll area of the focused window |
| `nextclick.reload` | Reload `~/.config/nextclick/config.json` (this also happens automatically when you save it) |
| `nextclick.clear_history` | Forget the click history used for smart labels |

Suggested hkd bindings. For a `capslock` trigger, hkd fires `on_press` when Caps goes down and `on_release` only when Caps was tapped alone:

```json
{ "trigger": "capslock",  "on_press": "click.prefetch", "on_release": "click.show" },
{ "trigger": "hyper+space", "on_press": "click.system" },
{ "trigger": "hyper+j",   "on_press": "scroll.show" },
{ "trigger": "hyper+/",   "on_press": "click.search" },
{ "trigger": "hyper+.",   "on_press": "click.repeat" }
```

## Keys

While labels are showing:

| Key | Action |
|---|---|
| letters | type a label; the click happens as soon as the label is complete |
| hold ⇧ / ⌘ / ⌥ on the last letter | right-click / ⌘-click / move the pointer there without clicking (hover) |
| the last letter again, quickly | double-click |
| `.` | repeat your last click in this app |
| Space | cycle labels that are stacked on top of each other |
| ⌫ | undo a letter |
| `?` | cheat sheet |
| Esc | close |

In scroll mode: `hjkl` (or the arrow keys) to scroll, hold ⇧ to go faster, `d`/`u` for half a page, `gg`/`G` for top/bottom, Tab or `1`-`9` to switch area, Esc to stop. Any other key leaves scroll mode and goes through to the app.

## Config

`~/.config/nextclick/config.json` (or `$NEXTCLICK_CONFIG`). Every key is optional; see `config.json` in this repo.

| Key | Default | |
|---|---|---|
| `theme` | `"codex"` | `codex` (Solarized in light mode, Gruvbox in dark, matching Codex), `claude`, `sunset`, `classic` (yellow), `midnight`, `frost`, `solarized`, `gruvbox` |
| `label_keys` | `"ASDFJKLEWRUIO"` | characters labels are built from |
| `label_size` | `12` | font size in points |
| `smart_labels` | `true` | frequent targets get the shortest labels, and labels stay put. `false` = nothing is written to disk |
| `auto_click` | `true` | `false` = a complete label only selects; Return clicks |
| `chain_clicks` | `false` | labels come back after each click until Esc |
| `double_click_ms` | `280` | window for typing the last letter again |
| `restore_pointer` | `false` | move the pointer back after a click |
| `hide_cursor` | `true` | hide the pointer while labels are up |
| `sounds`, `volume` | `false`, `0.35` | small synthesized pop/tick |
| `menubar`, `status_items`, `dock` | `true` | which system UI `click.system` labels |
| `mission_control` | `true` | label window thumbnails automatically when Mission Control opens |
| `enable_ax` | `true` | turn on accessibility trees in Chromium and Electron apps |
| `experimental_ax` | `false` | also Firefox, Zen and Spotify |
| `web_fast_path` | `true` | one search-predicate query per web page instead of a full tree walk |
| `hit_test` | `true` | native apps: drop targets another element covers (the element at the label's spot must be the target, inside it, or a container of it). Web content skips this, because Chromium's hit test only returns the whole page |
| `ignored_apps` | `[]` | bundle IDs where nextclick does nothing |
| `scroll` | | `keys` (`"hjkl"`), `speed` (1400 px/s), `dash` (3×), `arrows`, `numbers`, `idle_exit` (s, 0 = off), `restore_pointer` |

## Build and test

```sh
swift build
swift test
```

The tests use Swift Testing. They cover labels, configuration, history persistence, geometry, scrolling, and app detection. Check Accessibility behavior in a host app using the checklist below.

## How it works

1. **Scan** (serial AX queue). The focused window is walked depth-first: each element's attributes come back in one `AXUIElementCopyMultipleAttributeValues` call, children are clipped to their scroll areas, and tables report only their visible rows. Web areas use a single `AXUIElementsForSearchPredicate` query. Open menus, menu-bar items, status items (`AXExtrasMenuBar`, queried concurrently with a 50 ms timeout) and Dock items are added. If Mission Control is open, only its window thumbnails are labeled.
2. **Labels.** Balanced, prefix-free strings, shortest first. With smart labels, each target's identity is a SHA-256 of its role, name and coarse window-relative position (no text is stored). Its click history decays with a 14-day half-life; favourites get the shortest labels and keep them.
3. **Overlay.** One borderless panel per screen, ignoring the mouse, at the assistive-tech window level. The badges are CALayers.
4. **Keys.** A session event tap is installed only while a mode is active. It sits in front of hkd's tap and swallows keys. Letters are read through the current ASCII-capable layout, so Dvorak/Colemak work and input methods don't get in the way.
5. **Click.** Menus, the Dock, status items and Mission Control get `AXPress`. Everything else gets real mouse events at the activation point, after a hit test confirms the point lands on the target; if it doesn't, it falls back to `AXPress`.

## Permissions and privacy

- Uses hkd's **Accessibility** permission. Nothing extra for clicking or scrolling.
- `~/Library/Application Support/nextclick/history.json` maps app bundle IDs to hashed keys, click counts, last-click time, and label. No button text, URLs or keystrokes are stored. Turn `smart_labels` off and nothing is written; `nextclick.clear_history` deletes the file.
- No network, no subprocesses, no clipboard, no screen capture.

## Nuances

- **Chromium/Electron:** `AXEnhancedUserInterface` (Chromium) or `AXManualAccessibility` (Electron) is turned on when the app activates, and turned off again in `stop()`. tiler already suspends enhanced UI while it moves windows, so the two don't fight. The first scan right after enabling waits 300 ms for the app to build its tree.
- **Private APIs, guarded:** `CGSSetConnectionProperty("SetsCursorInBackground")` (needed to hide the pointer from a background process; skipped if missing), and the Dock's `AXExpose*` notifications for Mission Control. Either can break in a future macOS.
- **Speed notes.** Per-scan cost is mostly round trips to the target app, which answers one request at a time; SwiftUI apps like Messages are slow, roughly 1 ms per element. What keeps it fast:
  - Children come in the same batched read as attributes.
  - "Pressable?" probes are cached per element, so a repeat scan in Messages takes ~100 ms instead of ~300.
  - The visibility check only hit-tests targets under a window that's in front: the app's own popovers and sheets, or another app's normal windows. Other apps' floating overlays, like ChatGPT's companion window, are ignored.
  - In Chromium/Electron apps, a scan that runs right after accessibility is switched on and finds almost nothing is retried once after 300 ms.
- **Secure input** (password fields, some terminals) blocks event taps, so labels can't be typed there.
- Scroll mode warps the pointer to the area's centre, because macOS sends scroll events to whatever is under the pointer. It's restored on exit.

## Debugging

```sh
/usr/bin/log stream --predicate 'subsystem == "com.nkannan.nextclick"' --info
```

Each scan logs its target count and per-phase timings, e.g. `217 targets in 104 ms [mc 1, window(227) 32, menubar 1, status 53, dock 4]`. Use the full path: zsh's built-in `log` command shadows `/usr/bin/log`. `hk run click.show` toggles labels without pressing a key.

## Manual test checklist

1. `capslock` → labels on the Finder window only (sidebar rows, toolbar, files). `hyper+space` → menu bar, status items, Dock.
2. Type a label → click. ⇧ on the last letter → context menu. Same letter again quickly → double-click (opens a file).
3. `.` → repeats the last click. Esc → closes. A mouse click → closes.
4. Safari/Chrome page → links labeled (fast path). Slack/VS Code (Electron) → buttons labeled after the first activation.
5. Mission Control → thumbnails labeled → type a label → that window comes forward.
6. `hyper+j` → scroll mode: j/k smooth, ⇧ faster, d/u, gg/G, Tab switches area, Esc restores the pointer.
7. `hyper+/` → type "save" → Return clicks the Save button.
8. Set `"smart_labels": false` → click → `history.json` doesn't change.

## License

[MIT](LICENSE).
