# Nit Picker: security and bug review (9 October 2026, at `68ac8e2`)

**Status:** everything below is fixed. H1 and H2 are in `d3cc740`; the rest are in the commit after it. Two parts of L10 need the owner: Developer ID signing, and actually running notarization. The script now staples the app too, but that path hasn't been run.

Scope: all of `NitPicker/`, `project.yml` (entitlements, Info.plist), `Packages/FFmpegKit`, `scripts/make-dmg.sh`. Spikes and tests were only skimmed.

The app's attack surface is **untrusted media and subtitle files**. They are parsed by FFmpeg and libmpv (C code), and by the app's own Swift parsers. Sidecar subtitles next to a video are read **automatically** when the video opens. The sandbox is the main safety net, and it is set up well. The findings below are things the sandbox doesn't cover: crashes, races, and network access through the `network.client` entitlement.

**How each finding was checked:** **Reproduced** means the real source was compiled and run against crafted input. **By reading** means the finding comes from the code alone and was not run.

---

## High: crashes from a crafted subtitle file

Both crashes are in code that runs automatically. Opening a video whose folder holds a malicious `.srt`/`.ass` file with the same base name crashes the app, and it crashes again on every later open of that video.

### H1. `ASSParser` reads past the end of its array when `Format:` puts `Text` before `Start`/`End` (Reproduced: SIGTRAP)
`NitPicker/Subtitles/ASSParser.swift:29-34`

```
[Events]
Format: Text, Start, End
Dialogue: hello,0:00:01.00,0:00:02.00
```
`textIndex = 0`, so the split makes 1 part and `parts.count == textIndex + 1` passes. Then `parts[startIndex]` (index 1) traps.

**Fix:** the parser only splits off fields that come before `Text`, so require that:
```swift
guard let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"),
      let textIndex = fields.firstIndex(of: "text"),
      startIndex < textIndex, endIndex < textIndex else { return nil }
```

### H2. `SubtitleTimestamp.parse` integer overflow (Reproduced: SIGTRAP)
`NitPicker/Subtitles/SubtitleDecoding.swift:42-51`

`9223372036854775807:00:00,000 --> …` parses as an `Int` and then overflows at `hours * 3600`. This parser is used by SRT, WebVTT and ASS.

**Fix:** put an upper bound on hours, for example:
```swift
hours >= 0, hours < 100_000, minutes >= 0, wholeSeconds >= 0
```
You could also do the arithmetic in `Double`. Add both inputs above to `SubtitleTests` as regression tests.

---

## Medium

### M1. A superseded `open()` can close the new file's engine (By reading)
`NitPicker/Player/PlayerModel.swift:180-188`

Sequence:
1. File A starts loading (an MKV that will fail over to mpv).
2. The user opens file B. The new task tears down A, attaches B's engine and starts loading it.
3. A's `engine.load` then fails with `needsCompatibilityMode`. The `catch` doesn't check cancellation, so it calls `discardEngine()`. That closes **`self.engine`, which is B's engine**. Then it attaches an mpv engine for A.

The result is that B never plays. The model stays in `.loading` or shows the wrong file, and an mpv engine is attached for the old URL.

**Fix:** check for cancellation before switching engines. Also make the fallback discard only its own engine:
```swift
} catch let error as PlaybackError where error.wantsCompatibilityEngine {
    try Task.checkCancellation()
    guard self.engine === engine as AnyObject else { throw CancellationError() }
    discardEngine()
    ...
```
A per-open generation counter that is checked after every `await` in `performOpen` would be more robust. `FakeEngine` can script this sequence for a test.

### M2. Closing a remuxed file can block the main thread (By reading)
`SegmentMuxer.close()` (`SegmentMuxer.swift:100-109`) runs `queue.sync`, and the caller waits behind any segment cut that is in progress. The caller is the main actor, through `RemuxEngine.close()` (`RemuxEngine.swift:112`) and `switchAudio` (`:196`, `:199`). A cut that converts DTS/TrueHD to AAC, or one reading from a slow disk or network share, freezes the UI when you switch files or audio tracks.

**Fix:** make `close()` asynchronous and stop work that is in flight:
- Set a lock-protected `isClosing` flag. Check it in the `av_read_frame` loop in `cut`, or install an `AVIOInterruptCB` on `input`.
- Then `queue.async { avformat_close_input(...) }`.
- Or call `session.stop()` from `Task.detached`.

### M3. The compatibility engine can follow references in a local file out to the network (By reading, needs a check)
The sandbox grants `network.client` because of the loopback server. libmpv therefore has open network access. Some local files can point to remote URLs: playlists (`#EXTM3U`/HLS, which mpv treats as "safe" for http), EDL files, and Matroska ordered chapters/linked segments. Opening such a file in compatibility mode can make requests to an attacker's server. That leaks the user's IP and the fact that the file was opened, and it feeds further attacker-chosen media into the decoders.

**Fix (hardening):** add these to `MPVEngine.options` (`MPVEngine.swift:125-130`):
```swift
("access-references", "no"),   // don't follow playlists, EDL, references
("ordered-chapters", "no"),    // don't open other files by segment UID
("load-unsafe-playlists", "no"),
("demuxer-lavf-o", "protocol_whitelist=[file]"),
```
Check the effect with an `.m3u8` renamed to `.avi` that points at `http://127.0.0.1:<port>/`, with `nc -l` listening on that port. Check that normal AVI/MKV playback still works afterwards.

### M4. Possible use-after-free in `MPVHandle.destroy()` on the timeout path (By reading)
`NitPicker/Engine/MPV/MPVHandle.swift:72-77`

If the event thread hasn't returned within 3 s, `mpv_terminate_destroy(current)` still runs. The event thread may be inside `mpv_wait_event(current, 0.25)` at that moment, which is undefined behaviour.

**Fix:** set `handle = nil` and call `mpv_wakeup(current)`. Then wait for `eventThreadDone` with no timeout (this already runs off the main actor). If you want to keep a timeout, leak the handle on timeout rather than free it while it may still be in use.

Also, `Thread { [weak self] in self?.runEvents() }` holds `self` strongly for the whole loop. That means `deinit` can never be what stops the loop. The current code is fine because `MPVEngine.close()` always calls `destroy()`, but leave a comment so nobody relies on `deinit`.

### M5. Numbers from the file are converted to integers without checks (By reading)
A crafted MKV can make these trap:
- `MKVProbe.swift:172` and `:202`: `Int64(($0 * 1000).rounded())`. A huge or infinite timestamp (bogus Cues, odd `time_base`) traps, and so does `Duration.seconds(_:)` on a non-finite value.
- `SegmentMuxer.swift:183`: division by `av_q2d(time_base)`. A zero numerator gives ∞, and `Int64(∞)` traps.
- `HLSPlaylists.swift:10`: `Int(longest.rounded(.up))` has the same problem when keyframe times are absurd.

**Fix:**
- Drop keyframe times that are not finite or fall outside `0...(duration + margin)` before rounding.
- Check `time_base.num > 0 && time_base.den > 0` before using it, and fail with `Failure.cannotOpen` otherwise.

---

## Low / hardening

| # | Where | Issue | Fix |
|---|---|---|---|
| L1 | `MKVProbe`, `SegmentMuxer`, `MKVSubtitleReader`, `MPVSourceProbe`, `MPVThumbnailer` | `avformat_open_input(…, nil, nil)` probes with every demuxer. A file named `.mkv` that is really HLS, concat or DASH gets those demuxers, which open further URLs. FFmpeg's default whitelist for local files (`file,crypto,data`) blocks the network, but local reads stay possible. | For the remux path, force `av_find_input_format("matroska")`. Everywhere, pass an options dict with `protocol_whitelist=file` and `format_blacklist=hls,concat,dash,…` (or a `format_whitelist`). |
| L2 | `PlayerWindowView.swift:74`, `NitPickerApp.swift:13` | Drag-and-drop and `onOpenURL` accept any `URL`: an `http://` link dragged from a browser, or a folder. The mpv path then plays `url.path` (wrong), and recents and resume store junk. | `guard url.isFileURL, !url.hasDirectoryPath else { return false }` |
| L3 | `SubtitleLoader.swift:13`, `SubtitleMarkup.swift:29` | A subtitle file is read whole, with no size cap. `runs(from:)` is O(n²) on a cue full of `<a` with no `>`, and it runs on the main thread during rendering. | Cap subtitle files (for example 20 MB) and cue length (for example 4 KB). In `runs`, stop searching for `>` after about 64 characters. |
| L4 | `MPVEngine.swift:366-372` | The `screenshot-raw` buffer is wrapped in a `CGImage` without checking `bytes.count >= stride * height` and `stride >= width * 4`. If the sizes disagree, Core Graphics reads past the end. | Add that guard in `screenshotRaw` or `captureFrame`. |
| L5 | `MPVEngine.swift:312-320` | Each seek starts a 3 s timer that resumes **all** waiters, so an older seek's timer releases a newer seek's waiter early. | Key the waiters by a seek ID and have the timer resume only its own. |
| L6 | `PlayerModel.swift:945` | `defer { isDetectingBlackBars = false }` in a cancelled detection run clears the flag for a newer run. Two runs can then overlap. | Clear the flag only if the task is still the current `blackBarTask` (compare a generation number). |
| L7 | `ScreenshotStore.swift:29-33, 50` | Two problems. The name limit is 80 *characters*, but file names are limited to 255 *bytes* (emoji titles fail to save). And there is a check-then-write race between `fileExists` and `.atomic` write. | Truncate by UTF-8 byte count, and write with `.withoutOverwriting`, retrying the next number on `fileWriteFileExists`. |
| L8 | `RemuxSession.swift:72` | `Int("-1")`/`Int("+3")` are accepted as segment indices. `SegmentMuxer.segment` rejects them, so this is harmless. | Add `index >= 0` so the server's own check is complete. |
| L9 | `Packages/FFmpegKit/Package.swift`, `.gitignore` | MPVKit is pinned by tag, and `Package.resolved` lives in the gitignored `.xcodeproj`, so the resolved revision isn't recorded. FFmpeg and libmpv parse every untrusted file, and PLAN.md calls MPVKit lightly maintained. | Pin by `revision:` (or commit a resolved file). Watch FFmpeg/libmpv/libass/dav1d security advisories and bump promptly. |
| L10 | `project.yml` / `make-dmg.sh` | Builds are signed ad hoc, so Hardened Runtime isn't in force (already in PLAN.md §0). The script staples the DMG but not the app. | Release builds only through the Developer ID path. Optionally notarize and staple the `.app` too, so a copied-out app still passes Gatekeeper offline. |

---

## Checked and found sound

- **Loopback server**:
  - Binds `127.0.0.1` only, with a random token prefix (a UUID, 122 random bits) on every path.
  - Only fixed resource names can be served (no path traversal).
  - Headers are capped at 64 KB, and the Range parsing handles negative, overflowing and suffix ranges correctly.
- **Sandbox**: the entitlements are minimal (read-only access to user-selected files, app-scoped bookmarks, Pictures, network). Security-scoped access is started and stopped in balanced pairs in `PlayerModel` and `SubtitleTrackStore`.
- **libmpv configuration**: config files aren't loaded (libmpv's default), and `load-scripts=no`, `ytdl=no`, `input-default-bindings=no` and `input-vo-keyboard=no` are set. There is no IPC server. File paths are passed as command arguments, never as command strings.
- **Screenshots**: `safeName` strips `/ : \ NUL` and leading dots, so a metadata title can't escape `~/Pictures/Nit Picker`.
- **Other**:
  - Subtitle markup becomes `AttributedString` runs, never HTML.
  - No shell-outs.
  - The MediaPlayer closures are built in `nonisolated` functions, as CLAUDE.md requires.

## Suggested order
1. H1 and H2. Two small guards plus regression tests. They are the only findings an attacker can trigger just by placing a file next to a video.
2. M1 and M2. These are user-visible bugs: playing the wrong file, and UI freezes.
3. M3 and L1. Network and demuxer hardening, verified with a crafted file.
4. M4 and M5, then the low-priority table.
