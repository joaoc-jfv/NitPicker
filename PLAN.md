# Nit Picker — Project Plan

> **Nit Picker**: a nit is the unit of display brightness, and a nit-picker is someone who fusses over small details. Renamed from the working title "Halation" (the soft glow around bright highlights on film) in October 2026.
> A free macOS video player built for HDR highlights, spatial audio, and a Liquid Glass interface.

This document is the full build plan. It is written so that an engineer (or another model) can implement it phase by phase without needing the conversation that produced it. **Status:** every milestone in §7 is built: phase 1 (1.1–1.10), phase 2 (2.1–2.4), phase 3 (3.1–3.3) and phase 4 (4.1–4.5). What is left is in §0 ("What is left"): things only the owner can do (signing, accounts, keys), things nobody could check without a person or a real file, and a few small ideas. MP4, MOV and M4V play through AVFoundation; MKV and WebM are remuxed on the fly into HLS for AVFoundation; everything else plays in libmpv ("compatibility mode").

---

## 0. Where things stand (read this first)

*Written at the end of milestone 4.5 so work can continue from a fresh chat. Everything below is also true in the code and tests; the rest of this file is the design.*

### State

| Area | State |
|---|---|
| Phase 1 (MP4/MOV/M4V player, §7) | **Done**, milestones 1.1–1.10. |
| Phase 2 spike (`Spikes/MKVRemux/`) | **Done.** Approach confirmed on a real 4K Dolby Vision 8.1 + E-AC-3 JOC MKV; its README has the measurements. |
| 2.1 FFmpeg, `MKVProbe`, `LoopbackServer`, entitlements | **Done.** |
| 2.2 `RemuxEngine` (MKV plays, HDR/DV, Spatial Audio, seeking) | **Done.** Verified on the real file, not just generated clips. |
| 2.3 Tracks: audio switching, MKV subtitles, thumbnails | **Done.** Verified on the real file (see 2.3 notes). |
| 2.4 Audio conversion, files without Cues | **Done** (see 2.4 notes). Hardening items still open are listed below. |
| Phase 3 spike (`Spikes/MPVSpike/`) | **Done.** libmpv plays the real 4K DV file with hardware decoding and HDR passthrough. |
| 3.1 libmpv groundwork, `MPVEngine`, fallback routing | **Done** (see 3.1 notes). |
| 3.2 mpv polish: subtitles, thumbnails, Dolby Vision note | **Done** (see 3.2 notes). |
| 3.3 real-file checks, compatibility switch, resize fix | **Done** (see 3.3 notes). |
| 4.1 folder playlists, 4.2 black bars, 4.3 picture adjustments, 4.4 screenshots, 4.5 DMG script | **Done** (see the notes under §7 Phase 4). |
| Security and bug review (October 2026) | **Done** (see the review notes after the 4.5 notes). |

400 tests pass (`xcodebuild … test`). The Release app is 94 MB (universal binary; before libmpv it was 41 MB) and the disk image 43 MB. One commit per milestone; `git log` is the history.

### To start a session
1. Read `CLAUDE.md`, this section, §7 Phase 2, and `Spikes/MKVRemux/README.md`.
2. `xcodegen generate && xcodebuild -scheme NitPicker -destination 'platform=macOS' test`. The first build downloads the FFmpeg binaries (~100 MB).
3. `TestMedia/` (gitignored, never commit) holds one real file for manual checks: a 3840×1920 HEVC Dolby Vision profile 8.1 MKV, 55 minutes, 10.6 GB, two E-AC-3 5.1 JOC audio tracks (Italian first and default, then English), and 46 SRT subtitle tracks (including Forced and SDH). Open it with `open -a <built NitPicker.app> <file>`.

### What is left
**Needs the owner (accounts, keys, a decision):**
- **Signing and notarizing a release.** `scripts/make-dmg.sh` builds the Release app and the disk image and, given a *Developer ID Application* identity and a `notarytool` keychain profile, signs, notarizes and staples it (see 4.5 notes). This Mac only has an Apple Development identity, so that path has not been run.
- **Updates (Sparkle)**, the **website**, and **subtitle downloads** (OpenSubtitles needs an API key and consent screens): each needs an account or key the owner has to create and a hosting decision. Nothing was added for them, because code that points nowhere can't be verified.
- The **name check** (§9 item 6).

**Needs a person or a real file:**
- Dolby Vision actually switching the display into DV mode, how the JOC track sounds on AirPods, how HDR looks on screen and how the HDR screenshot looks in Photos on an HDR display.
- Real VP9, DTS, TrueHD, PGS/VobSub, AVI and AV1 files on the mpv engine (this FFmpeg build has no encoder for them, and none is in `TestMedia/`): those paths are libavcodec's decoders and libass, and were exercised only with MPEG-4, ASS, SRT and PCM that tests can generate.
- The sandbox's folder-access dialog (used by sidecar subtitles and folder playlists) end to end; only its failure path and a folder inside the app's own container were exercised.
- Phase 2 hardening on real files: big MKVs without Cues, converted (DTS/TrueHD) audio, HDR10+.

**Known limits and small ideas:**
- mpv tracks never get the Spatial Audio badge or system spatialization (see the 3.2 notes for why), and Picture in Picture is unavailable on mpv. ASS subtitles drawn by mpv can sit behind the control bar while it shows.
- HDR10+ is not detected (`HDRFormat.hdr10Plus` exists but nothing sets it): it is signalled in the bitstream, so it needs a decoded frame's side data.
- No visible playlist or queue (Next/Previous walk the folder), no shuffle.
- CPU of the Release app playing the real 4K Dolby Vision file through the remuxer, measured with `top` in 4.5: 17–23% of a core and 500–600 MB; the pre-3.2 build measures the same, so nothing regressed. The 8–10% in the 2.2 notes came from a different measurement (`ps`), which averages over the whole life of the process.

### Known gaps and things not verified
- **Not verified by eye or ear (needs a person):** Dolby Vision actually switching the display into DV mode; how the JOC track sounds on AirPods; HDR brightness on screen. The data path (tags, sample entries, flags, pixel format) is verified.
- Not verified by ear: that switching audio sounds right on AirPods (the owner reports Spatial Audio works). Not measured: how long the one-pass subtitle scan takes on a cold disk for the 10.6 GB file (subtitles were showing within seconds in the real app), and ASS styling beyond plain text (phase 3). Bitmap subtitles (PGS, VobSub) aren't read.
- `NitPicker.app` is signed ad hoc, so Hardened Runtime is off; real signing, notarization and Sparkle are phase 4.

### Decisions that belong to the owner
- **License for Nit Picker: decided, MIT** (§9 item 7). Public repo, free for now; premium features may come later as a closed module (open core), which MIT allows because the owner holds the copyright. Don't copy GPL code (IINA, mpv) into the app, and stay on MPVKit's LGPL variant. Still open: the name check (§9 item 6).
- "Dolby Vision" is used as the descriptive name (decided in 1.9, one place: `HDRFormat.badge`). "Dolby Atmos" is never shown; a test checks it.
- FFmpeg and libmpv come from MPVKit's release assets, whose README says it is lightly maintained. `Packages/FFmpegKit` now depends on the `MPVKit` package (LGPL variant, release 1.1.0-n9.0.2, pinned by its commit hash because a tag can move) and links its static libraries explicitly. AetherEngine (a library that already does this whole job) is the fallback or reference.

### Gotchas learned the hard way
- **`project.yml` is the source of truth** for the Xcode project, the Info.plist and the **entitlements**. XcodeGen rewrites `NitPicker.entitlements` from `entitlements.properties`; for milestones 1.1–1.5 it was regenerated empty and the app ran unsandboxed. Run `xcodegen generate` after adding or removing files.
- **Closures the system calls on its own queue** (MediaPlayer artwork and remote commands) must be created in a `nonisolated` function, or Swift 6 traps at run time. Fake services in tests can't catch this; launch the real app.
- Sandbox: both `network.server` and `network.client` are needed for the loopback server (verified). The sandbox is enforced for network here.
- AVFoundation can't describe HLS tracks (see 2.2 notes); `AVAssetResourceLoader` can't feed HLS media.
- libavformat parses Matroska Cues lazily (first seek); the muxer needs `strict unofficial` for the Dolby Vision box and `delay_moov` for `dec3`. The details are in the spike README.
- **Open media through `FFmpegInput.open`**, never `avformat_open_input` directly: it allows local files only (`protocol_whitelist=file`), the remuxer's readers pass `remuxFormats` so a manifest or concat list posing as an MKV is refused, and `SegmentMuxer` passes an interrupt so `close` can stop a read. Timestamps from a file go through `FFmpegTimestamp.seconds`, which turns nonsense into nil instead of a crash. The mpv options `access-references=no` and `demuxer-lavf-o=protocol_whitelist=[file]` keep libmpv off the network (see the review notes).
- Linking FFmpeg statically needs its dependencies (gmp, gnutls, nettle, hogweed, dav1d, uavs3d, lcms2) linked explicitly in `Packages/FFmpegKit/Package.swift`.
- Swift Testing runs tests in parallel; tests that touch `UserDefaults` use throwaway suites (`TestPreferences`, `PlayerServices.testing`). `FakeEngine` (tests) scripts a `PlaybackEngine`.
- **Checking the real app**: `open -a <app> <file>`, then System Events scripting (`osascript`) for keys, menus and window geometry, `screencapture -R x,y,w,h` of the window, and `CGEvent` for real clicks (a tiny Swift tool; `System Events` clicks don't register as double-clicks). It only works while the Mac is unlocked. A stale "Nit Picker quit unexpectedly" dialog after a crashing test run is harmless; check `~/Library/Logs/DiagnosticReports/NitPicker*.ips` for real crashes.
- **mpv measures its output size once** (when the video output starts) and only measures again when the output restarts (see 3.3 notes): a black window, or a picture in a corner, with playback running. It only showed in the real app: after any change near the mpv view or the window sizing, launch the app with `forceCompatibilityEngine`, open a large file (the window resizes) and then a second file.
- Generated test media: `TestVideo.make` (AVAssetWriter) plus `MKVFixture` (FFmpeg remux into Matroska with chapters, subtitles, a Dolby Vision record) mean no media is committed.

---

## 1. Goals and non-goals

### Goals
- **Free** native Mac video player that looks at home on macOS 26+ (Liquid Glass).
- **HDR done right**: HDR10, HLG, and Dolby Vision (profiles 5 / 8.1 / 8.4) shown with real extended brightness (EDR) on capable displays, never washed out.
- **Spatial Audio**: object-based E-AC-3 (E-AC-3 JOC) tracks rendered as spatial audio on AirPods and Mac speakers, plus spatialized multichannel/stereo when the user wants it.
- **Broad format support**: MP4/MOV first, then MKV through remuxing, then everything else through a fallback engine.
- **All the basics**: subtitles, audio track switching, audio output mode, crop/aspect, playback speed, Picture in Picture, media keys, resume, keyboard control.

### Non-goals (for now)
- Streaming services, DRM, network shares/library servers (could come much later).
- Video editing or transcoding/export.
- iOS/iPadOS/visionOS versions (keep the engine layer platform-neutral where it costs nothing, but don't design for them yet).
- Object-based decoding of TrueHD or DTS:X height channels. No free decoder exists; those play as plain multichannel.

### Terminology rule
Use **"Spatial Audio"** everywhere user-facing: UI, menus, badges, README, App Store text, marketing. Never write "Dolby Atmos" in user-facing strings, because the name needs a Dolby license. In code and comments, use the technical name `E-AC-3 JOC` (or `eac3JOC`) for the codec.

---

## 2. The key constraint (why the architecture is hybrid)

| | AVFoundation (`AVPlayer`) | libmpv / FFmpeg |
|---|---|---|
| Containers | MP4, MOV, M4V, HLS. **No MKV** | Everything |
| Video codecs | H.264, HEVC, ProRes, AV1 (hardware on M3+) | Everything |
| HDR10 / HLG | Native EDR | Good (tone-mapped/EDR, more work) |
| Dolby Vision | Real DV (5, 8.1, 8.4) | Tone-mapped only |
| Spatial Audio (E-AC-3 JOC) | **Yes**, spatialized by the system | **No**, only passthrough to a receiver |
| TrueHD / DTS | No | Decoded to multichannel PCM |
| Subtitles | Embedded text tracks only | All, including ASS styling and PGS images |

**Conclusion:** AVFoundation is the only path to real Dolby Vision and Spatial Audio on macOS, so it is the main engine. MKV files are **remuxed on the fly** (no re-encoding) into something AVPlayer can play. Anything still unsupported falls back to **libmpv**, with a visible "Compatibility mode" note.

---

## 3. Architecture

```
┌──────────────────────────── SwiftUI + Liquid Glass UI ────────────────────────────┐
│  PlayerWindow · VideoSurface · ControlBar · Track/Speed/Crop panels · InfoHUD     │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                        │ observes
                              ┌─────────▼─────────┐
                              │   PlayerModel     │  @Observable, @MainActor
                              │ (UI-facing state) │  owns the active engine
                              └─────────┬─────────┘
                                        │ PlaybackEngine protocol
             ┌──────────────────────────┼──────────────────────────┐
             ▼                          ▼                          ▼
   AVFoundationEngine          RemuxEngine (phase 2)        MPVEngine (phase 3)
   MP4/MOV/M4V/HLS             MKV → fMP4/HLS → AVPlayer    libmpv fallback
             ▲                          ▲                          ▲
             └──────────── EngineRouter (uses MediaProbe) ─────────┘

   Shared services: MediaProbe · SubtitleRenderer (SRT/VTT, later ASS) ·
   NowPlayingService · ResumeStore · RecentFiles · Preferences
```

### 3.1 `PlaybackEngine` protocol (sketch)

Every engine conforms to one protocol, so the UI never knows which engine is active.

```swift
@MainActor
protocol PlaybackEngine: AnyObject {
    var events: AsyncStream<PlaybackEvent> { get }   // state, time, tracks, errors
    var videoView: NSView { get }                    // view hosting the video layer

    func load(_ url: URL, startAt: Duration?) async throws
    func play()
    func pause()
    func seek(to: Duration, precise: Bool) async
    func step(frames: Int)                           // ±1 frame while paused

    var rate: Float { get set }                      // 0.25 ... 4.0
    var volume: Float { get set }                    // 0 ... 1
    var isMuted: Bool { get set }

    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }         // embedded tracks only
    var selectedAudioTrack: MediaTrack? { get }
    var selectedSubtitleTrack: MediaTrack? { get }
    func selectAudio(_ track: MediaTrack?)
    func selectSubtitle(_ track: MediaTrack?)        // nil = off

    var audioOutputMode: AudioOutputMode { get set } // .spatial, .stereo
    var capabilities: EngineCapabilities { get }     // e.g. supportsPiP, supportsDolbyVision
    func close()
}
```

Supporting types: `PlaybackState` (idle/loading/ready/playing/paused/ended/failed), `PlaybackError`, `PlaybackEvent` (state, time, duration, buffering, buffered range, media info, tracks changed), `MediaTrack` (id, kind, language, title, codec, channels, isDefault, isForced, `isSpatial`), `MediaInfo` (container, engine name, HDR format, codecs, coded `resolution`, `displaySize` with pixel aspect ratio applied, frame rate, bitrate; audio layout and chapters join it in 1.5 and 1.8), `AudioOutputMode`, `EngineCapabilities`. `HDRFormat` (.sdr/.hdr10/.hdr10Plus/.hlg/.dolbyVision(profile, compatibilityID)) lives in `PlaybackTypes.swift`, and `CropMode` with the crop panel (1.7). An engine instance serves one file; `PlayerModel` creates a new one for each open and applies its stored rate, volume, mute and output mode.

`PlayerModel` translates engine events into simple observable properties (`isPlaying`, `currentTime`, `duration`, `buffered`, `mediaInfo`, track lists, selected tracks) and holds UI-only state (controls visible, active panel, crop mode, external subtitle track).

### 3.2 Engine routing

`EngineRouter.engine(for: url)`:
1. `MediaProbe` inspects the file. For AV-native containers use `AVURLAsset` + `load(.isPlayable)`. For others, sniff the container: magic bytes, then libavformat in phase 2+.
2. If it's an AV-native container and all chosen tracks are playable → **AVFoundationEngine**.
3. If it's MKV/WebM and the video codec is H.264/HEVC/AV1 and the audio is AAC/AC-3/E-AC-3/ALAC/FLAC/Opus → **RemuxEngine**.
4. Otherwise → **MPVEngine**.
5. Until phase 3 exists, unsupported files show a clear error ("This format isn't supported yet") instead of failing silently.

---

## 4. Tech stack and project setup

- **Language/UI:** Swift 6 (strict concurrency on), SwiftUI app lifecycle, AppKit bridging where needed (`NSViewRepresentable` for the video surface, `NSWindow` tweaks).
- **Deployment target:** macOS 26.0 (Liquid Glass APIs). Dev machine runs macOS 27 / Xcode 27.
- **Bundle ID:** `com.joaocadide.nitpicker` (adjust if needed).
- **Project generation:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Commit `project.yml`; gitignore the generated `NitPicker.xcodeproj`. This keeps the project file reviewable and lets a model regenerate it without using the Xcode GUI.
- **Targets:** `NitPicker` (app), `NitPickerTests` (unit tests, Swift Testing), and later `NitPickerUITests` if needed.
- **Dependencies:**
  - Phase 1: none (Apple frameworks only: AVFoundation, AVKit, CoreMedia, MediaPlayer, SwiftUI, AppKit).
  - Phase 2+: FFmpeg libraries (libavformat/libavcodec/libavutil) and later libmpv + libass. Preferred source: **MPVKit** (Swift package shipping libmpv, FFmpeg, and libass as xcframeworks). Pick its **LGPL** variant unless we decide to open-source under GPL. *Verify the current package name, maintenance status, and license variants before adding it.*
- **Entitlements:** defined under `entitlements.properties` in `project.yml` (XcodeGen rewrites the `.entitlements` file from them, so editing the file by hand is lost; until 1.6 it had been regenerated empty and the app ran unsandboxed). App Sandbox; `com.apple.security.files.user-selected.read-only`; `com.apple.security.files.bookmarks.app-scope` (resume and recents across launches via security-scoped bookmarks). Hardened Runtime is enabled in build settings, but Xcode turns it off while signing ad hoc (`CODE_SIGN_IDENTITY: "-"`, used so the project builds without a team). Set a real signing identity for release builds. Phase 2 needs a loopback HTTP server (the spike showed `AVAssetResourceLoader` cannot serve HLS media), so the app has `com.apple.security.network.server` and `com.apple.security.network.client`. Both are required, as verified in the sandboxed test host (listening is denied without `server`; AVPlayer cannot reach the listener without `client`).
- **Distribution (later):** Developer ID + notarization, Sparkle for updates, GitHub Releases. App Store optional; the sandbox setup above keeps that open.

### Folder layout

```
NitPicker/
├── PLAN.md
├── CLAUDE.md
├── README.md
├── project.yml
├── .gitignore
├── NitPicker/
│   ├── App/            NitPickerApp.swift, AppDelegate.swift, AppCommands.swift
│   ├── Engine/
│   │   ├── PlaybackEngine.swift, PlaybackTypes.swift, EngineRouter.swift
│   │   ├── AVFoundation/   AVFoundationEngine.swift, AVTrackMapping.swift, PlayerLayerView.swift, PiPController.swift
│   │   ├── Remux/          RemuxEngine, RemuxSession, SegmentMuxer, SegmentPlanner, HLSPlaylists, MP4Boxes, MKVProbe, LoopbackServer, FFmpegInfo (phase 2)
│   │   └── MPV/            (phase 3)
│   ├── Media/          CodecNames.swift, ColorDescription.swift, MediaBadges.swift, InfoSections.swift, LanguageMatching.swift, MediaProbe.swift, HDRDetection.swift, AudioFormatDetection.swift
│   ├── Player/         PlayerModel.swift, PlayerModel+Shortcuts.swift, ChapterNavigation.swift, VideoLayout.swift, VideoGeometry.swift, TrackSelectionPolicy.swift, MediaTrack+Labels.swift, PlaybackSpeed.swift, Toast.swift, TimeFormatting.swift
│   ├── Subtitles/      SubtitleCue.swift, SubtitleDecoding.swift, SRTParser.swift, WebVTTParser.swift, SubtitleMarkup.swift, SubtitleLoader.swift, SidecarSubtitles.swift, SubtitleStyle.swift, SubtitleTrackStore.swift
│   ├── UI/
│   │   ├── Player/     PlayerWindowView.swift, VideoSurfaceView.swift, WindowController.swift, WindowSizing.swift, OpenPanel.swift, SubtitleOverlay.swift, SubtitleLayout.swift
│   │   ├── Settings/   SubtitleSettingsView.swift (⌘, window)
│   │   ├── Controls/   ControlBar.swift, TrackSlider.swift (scrubber and volume), ScrubPreviewView.swift, PanelRow.swift, TrackPanel.swift, CropPanel.swift, SpeedPanel.swift, TrackPanel.swift, SpeedPanel.swift, CropPanel.swift, VolumeControl.swift
│   │   ├── HUD/        InfoHUD.swift, FormatBadges.swift (the Spatial Audio tag), OSDToast.swift
│   │   └── Welcome/    WelcomeView.swift (drop zone + recents)
│   ├── Services/       NowPlayingService.swift, ResumeStore.swift, RecentFiles.swift, ThumbnailCache.swift, SleepPrevention.swift, PlayerServices.swift, Preferences.swift, FolderAccess.swift
│   └── Resources/      Assets.xcassets, Info.plist, NitPicker.entitlements
└── NitPickerTests/
```

---

## 5. Feature specs

### 5.1 HDR and Dolby Vision
- Render with `AVPlayerLayer` hosted in a layer-backed `NSView`. On Apple Silicon with an EDR-capable display, AVFoundation outputs HDR as EDR automatically. **Do not** put an `AVVideoComposition` or Core Image filter in the path for normal playback, because that can strip HDR/DV metadata and costs performance.
- Detection (`HDRDetection`): use `AVAssetTrack` media characteristics (`.containsHDRVideo`), the format description's transfer function (`kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ` → HDR10, `_ITU_R_2100_HLG` → HLG), and the Dolby Vision codec types (`dvh1`/`dvhe`, or HEVC with a `dvcC`/`dvvC` extension) → DV profile.
- Implementation notes (1.3): `AVPlayerLayer` switches to EDR by itself when HDR plays, so the layer needs no `wantsExtendedDynamicRangeContent` flag. `HDRDetection` works from the track's format description. Dolby Vision profile and compatibility ID come from the `dvcC`/`dvvC` record, so 8.1 reads as profile 8, ID 1 and 8.4 as profile 8, ID 4. HDR10+ can't be told apart from HDR10 there (its metadata is in the bitstream), so `.hdr10Plus` is never produced yet.
- Implementation notes (1.9): the top-right pill is built from the resolution (by the longer side, so 3840×1600 is still 4K), the HDR badge, and "Spatial Audio" when the selected track is spatial and the output mode is Spatial. Clicking it, or `I`, expands the info panel; `Esc` closes an open bar panel first, then the info panel, then leaves full screen. The welcome screen's posters are small JPEGs in the caches folder, written when a file opens (the same frame as the Now Playing artwork). Scrub thumbnails come from nearby keyframes on a grid of about 1% of the duration, cached per file.
- Show `AVPlayer.eligibleForHDRPlayback` in the info panel so users know if their display or setup can show HDR.
- Keep `AVPlayerItem.appliesPerFrameHDRDisplayMetadata = true` (the default) for DV and HDR10+.
- Badge in the HUD: `HDR10`, `HDR10+`, `HLG`, `Dolby Vision` (see open question about DV naming), or nothing for SDR.

### 5.2 Spatial Audio
- Set `AVPlayerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel` when the output mode is **Spatial** (the default).
- **Stereo** mode sets it to `[]` (no spatialization) for people who want a plain downmix.
- Detect E-AC-3 JOC tracks: codec `ec-3`, plus the JOC flag in the `dec3` box extension. The SDK has no media characteristic for it. `AudioFormatDetection` reads `flag_ec3_extension_type_a` and a non-zero `complexity_index_type_a` after the substreams (ETSI TS 102 366 Annex F.6), from the sample description atoms and, failing that, the magic cookie. It is tested against records built from the spec but **not yet against a real JOC file**, and which of the two sources CoreMedia fills is unconfirmed. Mark those tracks `isSpatial = true` and show a **Spatial Audio** badge.
- - AVFoundation has no public link from a selection option to its audio track, so `AVTrackMapping.pair` matches them: by position when the counts and codecs agree, else by language and codec. Forced-only subtitle tracks are kept in the model (for the "Off" rule in §5.3) but hidden from the list and from `S`.
- Remembered choices (`Preferences`): last audio language, subtitle choice (unset / off / language) and output mode. They are applied when a file opens (`TrackSelectionPolicy`), and changed only by the user's own picks.
- The audio track list labels each track with its language, title, codec, and channels, plus "Spatial" where it applies (for example "English · 5.1 · Spatial").
- Head tracking is controlled by the system (Control Center), not the app. Don't build a toggle for it.

### 5.3 Subtitles
- **Embedded:** from `AVMediaSelectionGroup` for `.legible`. Selecting one uses `AVPlayerItem.select(_:in:)`. "Off" means `nil`. Respect forced subtitles: when "Off", still show forced tracks that match the audio language.
- **External (sidecar):** auto-load `movie.srt`, `movie.en.srt`, `movie.vtt`, and so on from the same folder. The sandbox needs the user to grant folder access the first time, or use "Add Subtitle File…" in the panel. Parse SRT and WebVTT into `[SubtitleCue]` and render with our own `SubtitleOverlay` (SwiftUI text above the video, synced to the current time with a binary search over cues).
- **Styling (preferences):** font size (S/M/L/XL, as a fraction of the video height), background (none / shadow / box), position offset, set in the Settings window (⌘,) with a live preview. The delay is ±0.1 s per step (`Z`/`X`, also in the Subtitles menu), applies only to sidecar tracks, and resets for each file.
- Implementation notes (1.6): files are decoded as UTF-8 (BOM-aware, UTF-16 too), falling back to Windows-1252. Inline `<i>`, `<b>`, `<u>` are kept and every other tag or ASS override is dropped. Overlapping cues all show. The overlay reads the engine's live playhead about 30 times a second (the 4 Hz `currentTime` would be visibly late), sits in the video's own rectangle rather than the window's, and lifts clear of the control bar while it shows. Sidecars load after playback starts. With no embedded subtitles and no remembered choice, the first sidecar is selected. A remembered language picks the matching sidecar, and Off keeps them listed but hidden.
- Folder access: listing the video's folder can fail in the sandbox. The panel then offers "Find Subtitles in This Folder…", which asks for the folder and remembers it with an app-scoped security bookmark (`FolderAccess`). "Add Subtitle File…" always works. **Not yet checked in a strictly enforced sandbox:** on the dev Mac, a sandboxed build could still list ~/Documents, so only the failure path (a missing folder) is tested.
- **ASS/SSA and PGS:** phase 3 via libass and libmpv.

### 5.4 Audio tracks and channels
- Audio tracks come from `AVMediaSelectionGroup` for `.audible`.
- Output mode: **Spatial** / **Stereo** (5.2).
- Volume 0–100% with a slider in the control bar, plus mute. An optional "boost" above 100% is out of scope for phase 1.
- Remember the preferred audio and subtitle language in Preferences and apply it automatically when a file opens.

### 5.5 Crop, aspect ratio, and zoom
- Implement by **sizing and positioning the `AVPlayerLayer` inside a clipping container** (`masksToBounds = true`), not with a video composition. This keeps HDR and DV intact and costs nothing.
- Modes:
  - Aspect override: Auto, 16:9, 4:3, 2.39:1, 2.00:1, 1.85:1, 1:1.
  - Crop presets: None, 2.39:1, 2.00:1, 1.85:1, 16:9, 4:3. These remove letterbox bars by scaling the layer so the chosen region fills the view.
  - Zoom: fit (default), fill, and step zoom with pan (later).
- `C` cycles through crop presets, with an on-screen toast showing the current mode.
- Implementation notes (1.7): `VideoGeometry.placement` is a pure function from container size, display size and `VideoLayout` to a clip rect and a video rect. `VideoSurfaceView` puts the player view inside a masked clip view and sets the two frames, animated unless Reduce Motion is on. An aspect override stretches the picture (`videoGravity = .resize`) before any crop is taken from it. A crop takes a centered region of the chosen ratio (wider than the picture trims top and bottom, narrower trims the sides). **Fit** shows that whole region inside the window and **Fill** covers the window with it. Subtitles are placed in the clip rect. Layout is per file and resets when another file opens. Zoom steps and pan are still to do. The display size comes from the track's format description (pixel aspect ratio and clean aperture), because `naturalSize` already has the PAR in it.
- Phase 4: automatic black-bar detection by sampling a few frames with `AVPlayerItemVideoOutput` at load time.

### 5.6 Playback speed
- Presets 0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75×, 2×, and a fine slider 0.25×–4×.
- Use `AVPlayerItem.audioTimePitchAlgorithm = .timeDomain` (or `.spectral`; test both for voice quality) so pitch stays natural.
- `[` / `]` step speed down/up, `\` resets to 1×. Show a toast on change.
- Use `AVPlayer.defaultRate` (macOS 13+) so pressing play resumes at the chosen speed.
- The speed panel has the presets and a logarithmic fine slider (0.25× at the left, 1× in the middle, 4× at the right, in 0.05 steps).

### 5.7 Other basics (phase 1)
- **Open:** drag and drop onto the window or Dock icon, File ▸ Open (⌘O), Open Recent, "Open With" from Finder. Declare document types in Info.plist: `public.movie`, `public.mpeg-4`, `com.apple.quicktime-movie`, `public.avi`, plus imported UTIs for `org.matroska.mkv` and `org.webmproject.webm`.
- Implementation notes (1.8): `PlayerModel` takes a `PlayerServices` bundle (preferences, folder access, Now Playing, resume, recents, sleep) and an engine factory, so tests run it with fakes and a scripted `FakeEngine`. Resume records are keyed by path, with a fallback to the same name and size for moved files. Opening is by security-scoped bookmark in Open Recent. Now Playing publishes on state, duration, seek and rate changes only (the system extrapolates the elapsed time), and the artwork is a keyframe from about 10% in. Remote command handlers hop to the main actor. Closing the window quits the app (`AppDelegate`), and quitting saves the position. Chapter navigation: `⌥→` goes to the next chapter and `⌥←` restarts the current chapter, or goes back one when it is within 3 s of its start.
- **Resume:** save the position every ~5 s and on close, using security-scoped bookmarks. When reopening, offer "Resume from 42:10" as a glass toast with a button, auto-dismissed after ~6 s. Don't save if under 30 s in or within the last 3% of the file.
- **Picture in Picture:** `AVPictureInPictureController(playerLayer:)`. Button in the control bar.
- **Now Playing and media keys:** `MPNowPlayingInfoCenter` (title, duration, elapsed, rate, artwork from a frame) and `MPRemoteCommandCenter` (play, pause, toggle, skip ±10 s, change position).
- **Chapters:** read `AVAsset` chapter metadata groups. Show tick marks on the scrubber and a chapter list in a menu. `⌥←`/`⌥→` jump between chapters.
- **Frame stepping:** `,` and `.` while paused (`AVPlayerItem.step(byCount:)`).
- **Full screen:** native full screen (`F` or ⌃⌘F), double-click on the video toggles it.
- **Sleep:** keep the display awake while playing (`IOPMAssertion` or `ProcessInfo.beginActivity`).
- **Scrub preview thumbnails:** `AVAssetImageGenerator` with a small cache, shown above the scrubber on hover. It's fine to land this at the end of phase 1.

### 5.8 Keyboard shortcuts (default)

| Key | Action |
|---|---|
| Space | Play/Pause |
| ← / → | Seek −5 s / +5 s |
| ⇧← / ⇧→ | Seek −30 s / +30 s |
| ⌥← / ⌥→ | Previous / next chapter |
| , / . | Frame step back / forward (paused) |
| ↑ / ↓ | Volume ±5% |
| M | Mute |
| F | Full screen |
| [ / ] / \ | Speed down / up / reset |
| S | Cycle subtitles (including Off) |
| A | Cycle audio tracks |
| C | Cycle crop presets |
| Z / X | Subtitle delay −/+ 0.1 s |
| I | Toggle info panel |
| ⌘O | Open |
| Esc | Exit full screen / close panel |

Landing order: everything except the rows below shipped in 1.4. Audio and subtitle cycling (A/S) work on the engine's embedded tracks now and get their panel and preferences in 1.5. Subtitle delay (Z/X) comes with 1.6, crop (C) with 1.7, chapters (⌥←/⌥→) with 1.8, and the info panel (I) with 1.9. Esc leaving full screen is AppKit's own behavior.

All shortcuts also appear in the menu bar (Playback, Audio, Subtitles, Video menus) so they're discoverable and accessible.

---

## 6. Liquid Glass UI design

**Principle:** the video is the content and glass is the chrome. Controls float over the video and disappear when not needed.

- **Window:** `.windowStyle(.hiddenTitleBar)`, full-size content view, the video fills the window edge to edge. Traffic lights float over the video and fade with the controls. The window resizes to the video's aspect ratio when a file opens: native size, at least 640 pt wide, capped to 80% of the screen (`WindowSizing`). It is not aspect-locked afterwards. Black window background.
- **Control bar:** a floating capsule, bottom-center, inset 20 pt from the bottom, max width ~720 pt. Uses `.glassEffect(.regular.tint(.black.opacity(0.3)).interactive(), in: .capsule)` (the dark tint keeps white controls readable over bright video; the track panel uses a 0.4 tint) inside a `GlassEffectContainer` so panels can **morph out of the bar** (shortcuts are menu key equivalents with no modifier, so they win over a focused slider; auto-hide runs in `PlayerModel`, which restarts nothing on mouse movement and just moves a last-activity timestamp) (with `glassEffectID` and a `@Namespace`).
  - Left: play/pause, −10 s, +10 s.
  - Center: elapsed time · scrubber (buffered range, chapter ticks, hover thumbnail) · remaining time (click to toggle total).
  - Right: volume, **Audio & Subtitles** (one button, one panel with two columns like the Apple TV app), speed, crop/aspect, PiP, full screen.
- **Panels:** glass popovers that grow out of the control bar. Track rows show language, details, a checkmark, and a "Spatial" tag where it applies.
- **Info HUD (top-right glass pill):** format badges such as `4K · HDR10 · Spatial Audio`, shown with the controls. `I` expands it into a detailed panel: codecs, bitrate, frame rate, color primaries and transfer, HDR eligibility, audio layout, and the active engine (with "Compatibility mode" when it's mpv).
- **Toasts (OSD):** small glass capsules near the top-center for volume, speed, crop mode, subtitle delay, and seek amount. They fade after ~1.2 s.
- **Auto-hide:** while playing, hide the controls, traffic lights, and cursor after 2.5 s without mouse movement. Show them again on mouse move or any key. Keep them visible while paused or while a panel is open or the pointer is over the controls.
- **Empty state (WelcomeView):** a centered glass drop zone, "Drop a video to play", an Open… button, and a grid of recent files with thumbnails and progress bars below it.
- **Legibility:** put a soft black gradient behind the bottom ~120 pt **only while the controls are visible**, so glass stays readable over very bright HDR highlights. Test on bright snow/sky HDR scenes.
- Implementation notes (1.10): every animation checks Reduce Motion (SwiftUI ones through the environment value, the AppKit crop and window-chrome ones through `accessibilityDisplayShouldReduceMotion`). Reduce Transparency relies on the glass falling back to an opaque material by itself; our tints sit on top of that. A spinner shows after 0.4 s of loading or buffering. A file that fails, at open or mid-playback, drops its video and shows the message with an Open… button over the recents. The app icon is the Icon Composer bundle `Resources/AppIcon.icon`.
- **Accessibility:** respect Reduce Transparency and Reduce Motion (glass falls back automatically; also disable morph animations), VoiceOver labels on every control, full keyboard navigation, and Dynamic Type–style sizing for subtitles.

---

## 7. Phased roadmap

Each milestone ends with a working, runnable app. Commit at the end of each milestone.

### Phase 1 — Native player (AVFoundation only)

| # | Milestone | Done when |
|---|---|---|
| 1.1 | **Project skeleton**: `project.yml`, app target, test target, entitlements, Info.plist document types, `.gitignore`, README | `xcodegen && xcodebuild` builds an empty window app |
| 1.2 | **Engine core**: `PlaybackEngine`, types, `AVFoundationEngine` (load/play/pause/seek/rate/volume), `PlayerModel` | An MP4 plays with temporary basic buttons |
| 1.3 | **Video surface + window**: `VideoSurfaceView` hosting `AVPlayerLayer`, hidden title bar, aspect-fit window sizing, full screen | HDR10 and DV test files look visibly HDR on an XDR/EDR display |
| 1.4 | **Liquid Glass controls**: control bar, scrubber, auto-hide, toasts, keyboard shortcuts, menus | All controls and shortcuts from §5.8 work |
| 1.5 | **Tracks**: audio and embedded subtitle selection, Spatial/Stereo output mode, Spatial detection and badge, language preferences | Switching tracks works mid-playback; an E-AC-3 JOC file shows the badge and sounds spatial on AirPods |
| 1.6 | **Sidecar subtitles**: SRT/VTT parsers (unit tested), overlay renderer, styling, delay | An external SRT shows correctly timed and styled |
| 1.7 | **Crop/aspect/speed panels** | Every preset in §5.5 and §5.6 works and HDR stays intact while cropped |
| 1.8 | **System integration**: Now Playing, media keys, PiP, resume, recents, sleep prevention, chapters, frame step | Media keys work, resume prompt appears, PiP works |
| 1.9 | **Info HUD + welcome screen + scrub thumbnails** | Full UI from §6 is in place |
| 1.10 | **Polish pass**: accessibility, Reduce Transparency, error states, app icon | Ready for daily use with MP4/MOV |

### Phase 2 — MKV via remuxing

| # | Milestone | Done when |
|---|---|---|
| 2.1 | **Groundwork**: FFmpeg as a dependency (`Packages/FFmpegKit`), `MKVProbe` (tracks, HDR/DV, chapters, keyframe index), the production `LoopbackServer`, sandbox entitlements | The sandboxed app links FFmpeg, probes generated MKVs in tests, and AVPlayer plays a file it fetches from the loopback server. **Done.** |
| 2.2 | **`RemuxEngine`**: playlists from the keyframe index, per-segment muxing with the `tfdt` rewrite, shared init, HLS served by the loopback server, `EngineRouter` sends MKV there | A real HEVC + E-AC-3 MKV plays in the app with HDR/DV, Spatial Audio, instant seeking. **Done.** |
| 2.3 | **Tracks**: audio track switching, text subtitles extracted into the existing overlay, chapters from the file, `MediaInfo`/HUD for MKV, thumbnails | Switching audio and subtitles works on a multi-track MKV. **Done.** |
| 2.4 | **Audio fallback and hardening**: tracks AVPlayer can't play, files without Cues, error states, CPU and memory check | A typical MKV plays with under ~10% CPU; odd files fail with a clear message. **Done**, except the CPU target (see the notes). |

2.1 notes:
- `Packages/FFmpegKit` is a local package of MPVKit's prebuilt FFmpeg n9 **LGPL** static frameworks (avcodec, avformat, avutil, swresample), pinned by checksum, about 75 MB to download (against 1.7 GB for all of MPVKit). The static archives also reference gmp, gnutls, nettle, hogweed, dav1d, uavs3d and lcms2 (RTMP, TLS, AV1, colour management), so those binaries are pinned too and linked explicitly with `linkedFramework`, because nothing imports them. Updating FFmpeg means taking the new URLs and checksums from MPVKit's `Package.swift`.
- `MKVProbe` reports the keyframe index only when it reaches near the end of the file (`isCompleteIndex`). libavformat parses the Cues lazily, on the first seek, and probing alone can leave a partial index that must not be mistaken for the real one.
- `LoopbackServer`: IPv4 loopback only, random port, a random token as the first path component, GET/HEAD, single ranges, keep-alive. **Verified in the sandboxed test host: AVPlayer needs both `network.server` and `network.client`** (without `client` playback never starts).
- Release binary size with FFmpeg linked in: the app went from 9.2 MB to **40 MB** (binary 4.7 MB to 36 MB), measured in 2.2 once the engine called it.

2.2 notes (done; verified on the real 4K Dolby Vision 8.1 + E-AC-3 JOC MKV, 10.6 GB, 55 minutes):
- **Shape.** `RemuxEngine` wraps an `AVFoundationEngine` and points it at the HLS URL of a `RemuxSession` (probe, `SegmentPlanner`, `SegmentMuxer`, `HLSPlaylists`, `LoopbackServer`). Everything the inner engine does (tracks, HDR, PiP, speed, volume, frame step) keeps working. `EngineRouter` sends `mkv`, `mka`, `mk3d` and `webm` there; `avi`, `wmv`, `flv` and the like still get "This format isn't supported yet.".
- **What AVFoundation cannot tell us for an HLS stream.** `AVURLAsset.loadTracks` returns nothing and the audio selection group is made up, so the inner engine's media info and track lists are dropped. `RemuxSession.mediaInfo` and `.audioTrack` build them from the probe and the init segment (the `dec3` JOC flag gives `isSpatial`). Container shows as "MKV", engine as "AVFoundation (remuxed)".
- **Timestamps.** The mp4 muxer rebases every run to zero and writes an edit list. `MP4Boxes.rewrite` shifts each fragment's `tfdt` so presentation = `tfdt + composition offset - media_time + empty-edit delay` equals `pts - origin`, using the shared init's edit lists (empty edits and version 1 handled), and renumbers `mfhd` as `segment * 1000 + n`. A segment can contain several fragments (one per keyframe), which all move together. `SegmentMuxerTests` check every segment's first sample lands on its planned start (video within 20 ms, audio within one frame).
- **Choices made.** Audio: the remembered language if a copyable track matches, else the file's default, else the first (`RemuxSupport.chooseAudio`; the model passes the remembered language in through `PlaybackEngine.preferredAudioLanguage`). Copyable video: HEVC and H.264 only. Copyable audio: AAC, AC-3, E-AC-3, ALAC, FLAC. A file without audio plays video-only. Segments: at least 6 s, cut at keyframes; a tail under 3 s joins the previous segment. A bounded cache (160 MB) keeps recent segments.
- **Refusals with a message** (`RemuxSession.plan`): no video, unsupported video codec, only unsupported audio (DTS, TrueHD, ...), and no seek index (no Cues).
- **Measured on the real file:** opens and shows the first frame within about a second; a click at 60% lands on the right scene; CPU 8–10% and ~230–300 MB resident while playing 4K Dolby Vision; the info panel shows HEVC 3840×1920, 23.976 fps, 25.8 Mb/s, Dolby Vision 8.1, BT.2020, PQ, Italian E-AC-3 5.1 with the Spatial Audio flag.
- **Not done in 2.2** (2.3 and 2.4 did all of it except AV1): switching audio tracks, any subtitle track from the MKV, thumbnails, files without Cues, audio AVPlayer can't play.
2.3 notes (done; checked on the real 10.6 GB file: both audio tracks listed with the Spatial Audio tag, 46 subtitle tracks listed, English subtitles matching the dialogue, switching audio with `A` keeps the position, scrub previews show frames):
- **Audio switching.** `RemuxEngine` lists every copyable audio track. Choosing one starts a new `RemuxSession` for that stream (reusing the probe), reloads the inner engine at the current time and resumes if it was playing (a brief gap; the engine remembers whether play was last requested and sets that state explicitly after the reload, because a new item inherits the player's rate). Several quick picks collapse into the last one; a failed switch keeps the old track. The playing track's Spatial flag comes from its init segment; the other E-AC-3 tracks are checked in the background by opening a throwaway muxer (`RemuxSession.detectSpatial`) and the list updates when it answers. HLS alternate renditions were not tried.
- **Subtitles.** `MKVSubtitleReader` makes one pass over the file after playback starts and collects every text track at once (SubRip, ASS/SSA, WebVTT; ASS text is the part after the eighth comma, `\N` becomes a newline, vector drawings are dropped, overrides are stripped by `SubtitleMarkup`). Results arrive about once a second into a `SubtitleCueStore`. They are *not* routed through `SubtitleTrackStore`: the tracks are the engine's `subtitleTracks` (so forced/default flags, `TrackSelectionPolicy`, the remembered language, the S key and the menus work unchanged) and the new protocol method `PlaybackEngine.subtitleCues(for:)` hands the cues to `PlayerModel.activeSubtitleCues()`. `drawsSubtitles` decides whether the overlay and the delay controls apply, so Z/X delay works on MKV subtitles too. AVFoundation tracks keep rendering natively.
- **Thumbnails.** `SegmentMuxer.stillClip(at:)` cuts the keyframe at or before the time (0.6 s, video only, not cached) into a standalone MP4; `RemuxEngine.thumbnail` writes it to a temp file and uses `AVAssetImageGenerator` on it. The muxer keeps the keyframe's place in the file as an empty edit, so the image is requested at the keyframe's own time, not at zero. This also gives MKV welcome posters and Now Playing artwork.
- **HDR check of the remux path.** The display's EDR headroom rises from 1.2 to ~15 while the real file plays, and a dark shot cut from it renders at the same mean luma in QuickTime Player (29.0, plain MP4 from the spike tool), Nit Picker playing that MP4 (28.9) and Nit Picker playing the MKV (27.3), so the remux path looks like QuickTime's. The owner also confirmed by eye that HDR and Spatial Audio work. (`screencapture` tone-maps HDR, so those numbers show equivalence, not absolute brightness.)
- Test gotcha: `PlayerModel.seek` sets `currentTime` at once, so a test that waits on `model.currentTime` doesn't wait for the engine; use `model.livePlaybackTime()`.
- The track panel's subtitle list now scrolls (max 320 pt), because a file can carry dozens of tracks.
2.4 notes (done):
- **Converted audio.** Audio AVPlayer can't play but FFmpeg can decode (DTS, TrueHD, Opus, Vorbis, MP3, PCM, ...; `RemuxSupport.canTranscodeAudio` asks libavcodec) is decoded and re-encoded as **AAC** by `AudioTranscoder`: stereo 192 kb/s, 5.1 384 kb/s, anything wider mixed down to 5.1, rates above 48 kHz resampled to 48 kHz. **Correction to the plan: this FFmpeg build has no AC-3/E-AC-3 encoder** (only `aac`, `aac_at`, `alac`, `flac` and PCM), so E-AC-3 output was never possible; FLAC was not tried in HLS. The converter lives in the muxer and keeps its decoder/encoder state from segment to segment, so playing straight on is seamless (verified: packets contiguous, decodes back to the original sine with no dropouts or repeats). A seek rebuilds it (`resumeTime` != the next segment's start). The encoder's first frame is stamped one `initial_padding` late so its packets start on time and no edit list is needed. Tracks that play as they are beat convertible ones in the same language (an AC-3 core beats TrueHD); the info panel shows `DTS → AAC`; the track list keeps the source codec. Tests use a generated PCM track (`MKVFixture.Options.pcmAudio`), which must be interleaved with the video like a real file (a first version wrote it all up front and the cutter, correctly, ignored audio before the first video keyframe).
- **Files without Cues.** `RemuxSession.start` scans the file for keyframes (`MKVProbe.scanKeyframes`, one pass over the whole file) when the probe has no usable index. Caveat found on the way: `isCompleteIndex` accepts an index that ends within 30 s of the end, so on a file shorter than a minute a partial index can pass (the segments are then just longer; harmless).
- **Error states.** Unsupported audio now only refuses a codec nothing can decode (`This file's audio (X) isn't supported yet.`).
3.1 notes (done; checked in the real app on a generated MPEG-4 Matroska file; the real test file still goes through the remuxer):
- **Dependency, with its reason.** libmpv is the only way to play what AVFoundation and the remuxer can't (AVI/MPEG-4/VP9/WMV, DTS-HD, ASS and PGS subtitles). `Packages/FFmpegKit` now depends on the remote `MPVKit` package at 1.1.0-n9.0.2 (the plain LGPL `MPVKit` product) instead of pinning four FFmpeg binaries itself: the `Libavcodec/avformat/avutil/swresample` checksums are identical, so there is still one FFmpeg. The package exports `Libmpv` too (`import FFmpegKit`). Xcode links only what a target names, so Libmpv, Libavfilter/Avdevice/Swscale, Libass, freetype/fribidi/harfbuzz/unibreak, Libplacebo, Libdovi, shaderc, MoltenVK (a plain `.a`, linked with `-lMoltenVK`), lcms2, uchardet, bluray, luajit, ssl/crypto, gnutls/nettle/hogweed/gmp, dav1d and uavs3d are listed in the package's linker settings. First resolve downloads ~1.9 GB (all platform slices); the **Release app is 93 MB** (was 41 MB).
- **Spike** (`Spikes/MPVSpike/README.md`): HDR passthrough works with `target-colorspace-hint=yes` set before `mpv_initialize`; without it mpv tone-maps to SDR.
- **Shape.** `MPVHandle` (thin wrapper: options, properties, commands, an event thread feeding an `AsyncStream`), `MPVVideoView` (a `CAMetalLayer` that mpv draws into through `wid`, `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=moltenvk`, `hwdec=videotoolbox`), `MPVEngine` (the `PlaybackEngine`), `MPVMapping` (pure: tracks, colour names, containers). mpv starts paused (`pause=yes`) and `keep-open=yes`; the end of the file is `eof-reached`, not an event. Time events are thinned to ~4 a second.
- **Routing.** `EngineRouter` sends `avi`, `wmv`, `asf`, `flv`, `ogv`, `ogm`, `rm`, `rmvb`, `divx`, `xvid` straight to mpv. Any other file an engine can't play is retried there by `PlayerModel`: `PlaybackError.needsCompatibilityMode` (thrown by `RemuxEngine` for a video codec it can't copy, audio nothing can decode, no video, or no index even after scanning) and `.notPlayable` (AVFoundation). Other failures are not retried. If mpv fails too, its message is shown ("This file can't be played").
- **Deadlock found only in the real app.** mpv's video thread set `wantsExtendedDynamicRangeContent` with `DispatchQueue.main.sync` (as MPVKit's demo does) while the main thread waited for mpv's core in `mpv_get_property_string`: the window froze. The setter now uses `main.async`. Unit tests could not show this (no window); launch the real app for any change near the layer or mpv's threads.
- Language codes: Matroska/AVI use ISO 639-2/B (`fre`, `ger`, `chi`), which Foundation doesn't map; `LanguageMatching` now does.
- Tests: `LegacyFixture` makes MPEG-4 video in Matroska or MPEG-TS with FFmpeg's own encoder (this build has **no AVI muxer** and no VP9/DTS encoders, so those can't be generated). They play through `MPVEngine` in the test host, including pause, seek and the end; fallback routing is tested with fake engines.
3.2 notes (done):
- **Subtitles.** mpv draws the selected track itself (`PlaybackEngine.drawsSubtitlesNatively`), so the app's overlay has nothing to show for it, but the app's controls still reach it: Z/X delay maps to `sub-delay` (`setSubtitleDelay`; `PlayerModel.canDelaySubtitles` covers both kinds of subtitle), the size/background/position preferences map to `sub-font-size` (the fraction of a 720-high picture), `sub-border-style` (`outline-and-shadow` or `background-box`), `sub-back-color` and `sub-pos` (`MPVMapping.subtitleProperties`/`subtitlePosition`), and the overlay view reports how far up the subtitles must sit to clear the control bar (`setSubtitleLift`), so they lift while the controls show. These apply to plain-text tracks; ASS/SSA keeps its author's styling because mpv leaves it alone unless `sub-ass-override` says otherwise (so ASS subtitles can sit behind the control bar). Verified by rendering: tests capture the frame with `screenshot-raw` (this FFmpeg build has no image encoders, so `screenshot-to-file` fails) and compare pixels with and without the subtitle: libass draws a styled ASS line, extra-large text covers more than small, a box covers more than none, and lifting moves the text up the picture.
- **Sidecar files.** With an engine that draws subtitles itself, `.ass`, `.ssa`, `.sup` and `.idx` files next to the video are added with `sub-add` (flag `auto`, with the language and label read from the file name) so they join the embedded tracks in the panel and follow the remembered language; SRT/VTT stay in the app's overlay. For every other engine `.ass`/`.ssa` files are read as plain text by `ASSParser` (words and line breaks, no styling). The "Add Subtitle File…" picker accepts all of them.
- **Thumbnails.** `MPVThumbnailer` is a second decode path: libavformat seeks to the keyframe at or before the time, libavcodec decodes it in software, swscale scales it to RGBA (`Libswscale` is now exported by `FFmpegKit`). It serves scrub previews, welcome posters and Now Playing artwork. HDR sources come out with their transfer curve unmapped (dull), which is fine for a preview a few hundred pixels wide.
- **Dolby Vision.** mpv's properties can't tell DV from HDR10, so after loading, libavformat reads the configuration record (`MPVSourceProbe`, reusing `MKVProbe.hdrFormat`) and the info panel gets a note: "Dolby Vision 8.1 source, shown as HDR10 (tone-mapped)". The badge keeps saying what is on screen (HDR10).
- **Chapters** from the file show up and navigate on mpv (tested with a generated MKV forced onto the mpv engine).
- **Audio, decided not to do:** mpv 0.41's `avfoundation` audio output (AVSampleBufferAudioRenderer) exists in this build, but libmpv never sets `allowedAudioSpatializationFormats` (the string isn't in the binary), so switching to it would not give system spatialization; hooking the renderer's creation through the Objective-C runtime would, but it can't be verified without ears and could disturb A/V sync for every file. mpv tracks therefore stay `isSpatial == false` and play through `coreaudio`, with no Spatial Audio badge. Picture in Picture stays unavailable on mpv (the button is hidden).
3.3 notes (done; the first time the mpv engine was driven in the real app with a window that changes size, and with the real 4K file):
- **Bugs only the real app showed.** (1) A black window with playback running. It appeared when 3.2 added a SwiftUI subtitle overlay above the mpv view, and went away when the overlay was taken out, so the subtitle lift is now computed from the window size (`PlayerModel.nativeSubtitleLift`, fed by `onGeometryChange` on the window view) and no view is added. The cause that was later *demonstrated* is the next one, so the overlay may have only changed the timing; the overlay was not tried again. (2) mpv measures its output size once, when the video output starts. If the window grows to fit the video after the file opens, the swapchain grows but the picture stays laid out for the old size (a quarter-size picture in a corner, found on the 4K file; the 320×240 clip never showed it because the window didn't change size). If the output starts before the view has its size, mpv measures **1×1** and the picture is black (found by opening a second file in the same app, where `osd-dimensions` read 1×1). The only thing that makes mpv measure again is restarting the output (`vid no` then `vid <id>`; keepaspect, aspect override, `video-reconfig`, `window-scale` and `geometry` don't). `MPVEngine` compares mpv's `osd-dimensions` with the layer's drawable size 300 ms after the drawable size settles, after the file loads and after a seek, and restarts the output when they differ (at most three times in a row); the layer keeps showing the last frame in between. A test resizes the view after loading and waits for mpv's `osd-dimensions` to follow.
- **Checking mpv on any file.** Video ▸ Compatibility Engine reopens the open file on libmpv at the same position (and back); `defaults write com.joaocadide.nitpicker forceCompatibilityEngine -bool YES` plays everything on libmpv (`Preferences.forcesCompatibilityEngine`). The info panel says "Original channels" instead of "Spatial Audio" for the output on mpv and leaves out the Spatial Audio track row, because mpv does neither.
- **Measured on the real 4K Dolby Vision 8.1 file on mpv** (a Debug build, so not comparable with the 8–10% of the Release remux path): 15–17% of a core and 160–225 MB resident, hardware decoding, HDR10 shown ("4K · HDR10"), the info panel shows the Dolby Vision note, seeking by key works, and the picture fills the window after the window is resized.
- **Real-app checks done** with generated files in `TestMedia/` (`legacy-mpeg4.mkv`, `ass-h264.mkv`; both gitignored): the video shows, an embedded ASS cue is drawn by libass (it sits behind the control bar while the controls show, as expected for ASS), resume offers appear.
- **Not possible here:** this FFmpeg build has no VP9, DTS or PGS encoder and there is no AVI muxer, and `TestMedia/` has no such file, so those formats were not played; the mpv path for them is libavcodec's decoders, which MPVKit builds.
- **Spike done** (`Spikes/MKVRemux/, see its README): the approach below works on a real 4K Dolby Vision 8.1 + E-AC-3 JOC MKV, with two changes to the original plan. The transport is a **loopback HTTP server**, because `AVAssetResourceLoader` cannot feed HLS media (`-12881`). And every segment is cut by seeking and **using a fresh muxer, then rewriting `tfdt`**, with one init shared by all segments.
- Add FFmpeg libraries. The spike used MPVKit `1.1.0-n9.0.2` (FFmpeg n9, LGPL, static). Its README says it is "only suitable for learning" and "will not be maintained too frequently" (it did ship a release on 2026-10-07). Options for the real build: depend on MPVKit's FFmpeg binary targets only (Libavformat, Libavcodec, Libavutil, pinned by checksum), or depend on AetherEngine, which already implements this whole architecture (LGPL-3.0 with an App Store exception) and could be used as a dependency or as a reference.
- `MKVProbe`: read tracks, codecs, cues (keyframe index), chapters, and attachments with libavformat.
- `RemuxEngine`: present the MKV to AVPlayer as an HLS VOD stream with fMP4 segments, served by a loopback HTTP server bound to 127.0.0.1 (`NWListener`):
  - Build the master and media playlists up front from the cues (segments of roughly 4–6 s, aligned to keyframes). libavformat exposes the Cues after the first seek, so for a 55-minute 4K file that is 996 keyframes in ~0.3 s. The master playlist carries `CODECS` (`hvc1…`, `ec-3`), `SUPPLEMENTAL-CODECS` (`dvh1.08.06/db1p`) and `VIDEO-RANGE=PQ`, built from the `hvcC` and `dvvC` records.
  - Generate the init segment and each media segment on demand: seek the demuxer, copy packets (no re-encode) into fragmented MP4 with FFmpeg's mp4 muxer. It writes the right sample entries itself: `hvc1` + `hvcC` + `dvvC` for Dolby Vision (needs `strict unofficial`), `ec-3` + a `dec3` that carries the JOC flag (it parses the first packets, so use `delay_moov`). Details and the `tfdt` rewrite are in `Spikes/MKVRemux/README.md`.
  - Audio AVPlayer can't play in HLS (TrueHD, DTS, Opus, Vorbis, MP3, PCM) is decoded with libavcodec and re-encoded as AAC up to 5.1 (done in 2.4; there is no E-AC-3 encoder in this build).
  - MKV text subtitles (SRT/ASS) are extracted to our own overlay. ASS shows as plain text until phase 3.
- **Cost measured in the spike:** about 16 ms to cut a 7 s stretch of 4K after a cold seek 30 minutes into a 10 GB file, and ~0.3 s to open the file, probe it and read the Cues.
- **Fallback:** if building the playlist fails or there's no usable cue index, hand the file to MPVEngine (phase 3) or show a clear error.
- **Done when:** a typical HEVC + E-AC-3 JOC + SRT MKV plays with HDR/DV, Spatial Audio, subtitles, instant seeking, and track switching, using under ~10% CPU on Apple Silicon.

*Risk note:* this is the hardest part of the project. Prototype it as a standalone spike first: one MKV, one segment, played in AVPlayer. Confirm the approach before building it out.

### Phase 3 — mpv fallback engine
*Status: 3.1 done (engine core, routing, dependency); 3.2 is the polish list in "Where things stand".*
- `MPVEngine` using libmpv, drawing through `wid` into an EDR-enabled `CAMetalLayer` (Vulkan on Metal; done in 3.1; the render API was not needed). IINA's open-source code is a useful reference for the render loop, EDR, and event handling. IINA is GPLv3, so read it for ideas, don't copy code unless we go GPL.
- Map mpv properties to the protocol: `pause`, `time-pos`, `duration`, `speed`, `volume`, `aid`, `sid`, `track-list`, `video-crop`/`video-aspect-override`, `sub-delay`.
- ASS/SSA styled subtitles and PGS image subtitles through libass/mpv. Optionally reuse libass for remuxed MKVs too.
- "Compatibility mode" label in the info HUD; DV shows as "HDR (tone-mapped)".
- **Done when:** AVI/Xvid, VP9 WebM, DTS MKV, and ASS-styled anime files all play with working controls.

### Phase 4 — Nice to have

| # | Milestone | State |
|---|---|---|
| 4.1 | **Folder playlists**, next/previous episode detection (`S01E02`), "Up next" | **Done** (see 4.1 notes) |
| 4.2 | Auto black-bar crop detection | **Done** (see 4.2 notes) |
| 4.3 | Video adjustments (brightness, contrast, saturation) on the mpv engine | **Done** (see 4.3 notes) |
| 4.4 | Screenshots (⌘⇧S), HDR HEIC when the source is HDR | **Done** (see 4.4 notes) |
| 4.5 | Packaging: DMG script with signing and notarization. Sparkle, the website and subtitle downloads need accounts and keys that only the owner can create, so they are listed as owner tasks | **Done** (see 4.5 notes) |

4.1 notes (done; the card and the hand-over checked in the real app with two generated episodes in the app's own container, where the sandbox allows listing a folder):
- `FolderPlaylist` lists the videos next to the open file (by extension, hidden files skipped) in Finder's name order (`localizedStandardCompare`, so `E2` comes before `E10`). `EpisodeNumber.parse` reads `S01E02`, `1x02`, `EP05`/`Episode 5` and fansub-style ` - 05 [1080p]`; the series is the name before the marker, lowercased with punctuation squeezed out. `nextEpisode` is the next file only when it has the same series and a later number, so a movie or another show after the last episode never starts by itself, while Next/Previous still walk any folder.
- **Sandbox.** The app can only list a folder the user has allowed. The same permission as for sidecar subtitles is used (the track panel button now reads "Find Subtitles and Episodes in This Folder…"); `PlayerModel` holds the folder's security scope while a file is open, so the next file opens. Without it there is no playlist and the menu items stay disabled. The real-app check used the container's own temp folder; the permission dialog was not exercised.
- **UI.** Playback ▸ Next/Previous Video in Folder (⌘] and ⌘[). Over the last 15 s of an episode a glass card shows "Up next · starts when this ends", the episode (`S01E02` and the file name), Play Now and a close button that stops the hand-over for that file; at the end the next episode starts. The card never animates (no countdown), because an animating SwiftUI view over the mpv view was the first suspect for the black-window bug. Settings (⌘,) now has Playback and Subtitles tabs; "Play the next episode automatically" is on by default; with it off the card still offers the episode but nothing starts alone.
- Not done: playing a folder as a queue with a visible list, shuffle, "Next" for files in other folders.
4.2 notes (done):
- `BlackBarDetector` (pure) reads ten stills the engine gives through `thumbnail(at:maxSize:)` (at 5% to 86% of the file), so it works on every engine and needs no `AVPlayerItemVideoOutput`. A row or column is picture when more than 2% of its pixels are brighter than luma 28; a still with under 4% picture (a fade) is ignored; the bars are the smallest each side shows in any still (so a dark scene only makes it more cautious), at least four usable stills are needed, and bars under 2% are not cropped. The crop is centred, so only the thinner bar of a pair counts. The result is a ratio (`VideoLayout.detectedCrop`), applied by `VideoGeometry` like the presets, so it is still just frame sizing and HDR is untouched; choosing a preset or Reset clears it.
- Video ▸ Detect Black Bars (⇧C) and a row in the crop panel always answer with a toast ("Cropped black bars: 2.39:1" or "No black bars found"). Settings ▸ Playback ▸ "Crop black bars when a file opens" (off by default) runs it 1.5 s after opening and only speaks when it crops.
- Verified on a generated letterboxed MP4 through the real AVFoundation engine (2.39:1 found within 0.2) and on synthetic stills; not on a real letterboxed film (none in `TestMedia/`). HDR and mpv stills come out tone-mapped or dull, which doesn't matter for finding black.
4.3 notes (done):
- `VideoAdjustments` (-100...100, mpv's scale) are the engine's `supportsVideoAdjustments` / `setVideoAdjustments`; only `MPVEngine` says yes, because the AVFoundation path would need a video composition or Core Image, which breaks HDR and Dolby Vision (CLAUDE.md). The control bar shows a Picture button and a panel (three sliders, Reset) only when the open file plays on mpv; Video ▸ Picture Adjustments… opens the panel or, on another engine, says it needs the Compatibility Engine (which Video ▸ Compatibility Engine switches to at the same position). Values belong to the open file: they reset when another file opens, and carry over when the engine is switched.
- **Verified in the real app** by setting the sliders through the accessibility API and capturing the window: saturation −100 gives a grey picture, brightness 70 a much brighter one, and the paused frame updates at once. A unit test can't see it, because `screenshot-raw` in this build doesn't include the equaliser (its pixels didn't change with any of brightness, contrast, saturation or gamma); the tests check mpv's own state (values accepted, kept, clamped, applied before loading).
4.4 notes (done; checked in the real app on the 4K Dolby Vision file):
- File ▸ Save Screenshot (⌘⇧S) asks the engine for the frame on screen (`PlaybackEngine.captureFrame` → `CapturedFrame`) and saves it to **Pictures ▸ Nit Picker** as `<title> <time>.<ext>` without a save panel (new entitlement `com.apple.security.assets.pictures.read-write`; the real Pictures folder comes from the passwd entry, because `FileManager` answers with the container's copy). A name that is taken gets a number. File ▸ Show Last Screenshot in Finder reveals it.
- **AVFoundation** (and the remux engine through it): an `AVPlayerItemVideoOutput` is attached only for the moment of the capture (a player that is paused needs the same moment shown again, by a zero-tolerance seek, before a new output gets a frame). A buffer tagged PQ or HLG stays a pixel buffer and is written as **10-bit HEIC** in the matching BT.2100 colour space with Core Image (`heif10Representation`); anything else becomes a PNG. Core Image is used for stills only, never in the playback path. On the real 4K Dolby Vision 8.1 file the HEIC came out 3840×1920, 10 bits, profile "Rec. ITU-R BT.2100 PQ".
- **mpv**: `screenshot-raw` (this FFmpeg has no image encoders) gives the frame as mpv shows it, tone-mapped for HDR, saved as PNG. Taken off the main actor.
- Not verified: how the HEIC looks in Photos on an HDR display (a person must look); HLG files (the transfer is read from the buffer's tags, only PQ was exercised); Dolby Vision profile 5, whose buffers may not be plain PQ.
4.5 notes (done as far as this Mac allows):
- `scripts/make-dmg.sh` runs `xcodegen`, builds the Release app into `build/DerivedData`, verifies its signature, makes `build/NitPicker-<version>.dmg` (the app and an Applications link, compressed) and, with `--identity "Developer ID Application: …" --team ID` signs with a timestamp and the hardened runtime, and with `--notary-profile name` submits to Apple, waits, staples and checks with `spctl`. Run without options it signs as Xcode would here (ad hoc, hardened runtime flag set), which is for trying, not for sharing.
- **GitHub releases.** The README's download link is `releases/latest/download/NitPicker.dmg`, so each release needs an asset with exactly that name: `cp build/NitPicker-<version>.dmg build/NitPicker.dmg && gh release create v<version> build/NitPicker.dmg --title "Nit Picker <version>" --notes-file …`. v0.1.0 was published this way with the ad-hoc-signed image from this script, and its notes and the README explain "Open Anyway", since Gatekeeper blocks an un-notarized download. A notarized image removes that step; then drop the paragraph about it.
- **Run here:** the unsigned path end to end. The Release app builds, `codesign --verify --deep --strict` passes, the image mounts, holds a universal (arm64 + x86_64) 94 MB app, and the Release build launches and plays the real 4K file. **Not run:** the Developer ID signing and the notarization (no such identity or profile here), so the first real release should be done by hand once with the script's output watched; embedded frameworks (MPVKit's `Lib*` frameworks are copied into the app) must all be signed with the same identity, which Xcode does when it embeds them.
- With `--notary-profile`, the app itself is notarized and stapled before it goes into the image (then the image is), so a copy dragged out of the image passes Gatekeeper offline too. Not run here either (no profile).
- Not built, because each needs something only the owner can create: subtitle downloads (OpenSubtitles API: an API key and consent screens), Sparkle updates (an EdDSA key and a place to host the appcast), the website.

Review notes (October 2026, a security and bug pass over the whole app; the findings and their fixes are listed in the review commit's message):
- **Subtitle parsers**: an ASS `Format:` line with the times after `Text`, and a timestamp with an enormous hours value, crashed the app, and sidecar files load by themselves. Both are rejected now. Subtitle files over 20 MB are refused, and an inline tag must close within 256 characters, so a line full of `<` can't stall drawing.
- **libmpv and the network**: the sandbox allows outgoing connections (the loopback server needs them), and mpv followed a playlist or an HLS manifest saved as `.avi` to an http address. Verified with a listener on loopback (`MPVNetworkTests`): it was reached before, and isn't with `access-references=no`, `load-unsafe-playlists=no` and `demuxer-lavf-o=protocol_whitelist=[file]`. Normal playback is unchanged; files that pull in other files (EDL, ordered chapters in another file, playlists) no longer do.
- **libavformat**: every open goes through `FFmpegInput` (see the gotchas). FFmpeg's own default already kept a local file from reaching http; the whitelist makes that explicit. The remuxer's whitelist still lets a mislabelled MP4 open.
- **Opening files**: an open that is overtaken while its engine is still loading no longer hands its failure to the compatibility engine by closing the *new* file's engine (reproduced with `FakeEngine` before the fix). Drops and Finder only open local files, not web links or folders.
- **Closing a remuxed file** no longer waits on the main thread for a segment cut: `SegmentMuxer.close` raises an interrupt that libavformat polls and finishes on its queue.
- **mpv teardown**: `MPVHandle.destroy` no longer frees the handle while the event thread may still be waiting on it; if the thread doesn't stop within 10 s the instance is leaked rather than freed. Raw screenshots check the buffer size against stride × height; a seek's 3 s timeout only releases that seek.
- Smaller: a black-bar run overtaken by the next file no longer clears the next run's flag; screenshot names are cut to 200 bytes (emoji titles) and written without overwriting; the loopback server checks segment indexes are not negative.
- Not verified: that the interrupt really cuts short a read from a slow disk (the test shows `close` doesn't wait, not how fast a read gives up); the mpv teardown timeout path (it needs a hung mpv).

---

## 8. Testing strategy

- **Unit tests (Swift Testing):** SRT/VTT parsers (malformed input, overlapping cues, BOMs, CRLF), cue lookup at time T, `EngineRouter` decisions from mocked probe results, HDR/audio-format classification from synthetic format descriptions, crop/aspect geometry math, resume rules, time formatting.
- **Manual test matrix** (keep a `TestMedia/` folder, gitignored, with a `TestMedia/README.md` listing where each file came from):

| File | Checks |
|---|---|
| HEVC HDR10 MP4 | EDR brightness, badge, crop keeps HDR |
| HLG MOV (iPhone recording) | HLG badge, correct look |
| Dolby Vision profile 8.1 MP4 (iPhone recording) | DV badge, no green/purple tint |
| Dolby Vision profile 5 MP4 | Correct colors (P5 is easy to get wrong) |
| E-AC-3 JOC MP4 | Spatial badge, spatial on AirPods, Stereo mode works |
| AAC 5.1 MP4 | Spatialized multichannel |
| SDR H.264 with chapters and 2 audio tracks + 2 subtitle tracks | Track switching, chapters |
| Sidecar SRT/VTT (UTF-8, Latin-1, with BOM) | Encoding detection, timing |
| Phase 2: HEVC+E-AC-3 JOC MKV, HEVC DV P8 MKV, H.264+DTS MKV | Remux path and audio fallback |
| Phase 3: AVI/Xvid, VP9 WebM, ASS anime MKV, PGS subtitles | mpv path |

  Good sources: recordings from your own iPhone (HDR/HLG/DV), Apple's HLS example streams, and the Kodi sample files wiki. *Check the licenses before committing any of these. Never commit media to git.*
- **Performance:** check CPU/GPU use and energy in Activity Monitor for 4K HDR playback. The phase 1 target is close to QuickTime Player.

---

## 9. Risks and open questions

1. **MKV → HLS remuxing (phase 2)**: the spike is done and the approach is confirmed for HEVC + Dolby Vision + E-AC-3 JOC (`Spikes/MKVRemux/README.md`). Sandbox behaviour of the loopback server is settled (2.1). Still open: Dolby Vision on a DV display, subtitles and audio fallbacks, files without Cues.
2. **E-AC-3 JOC detection API:** no media characteristic exists, so the `dec3` parser (milestone 1.5) is the approach. Confirm it against a real JOC file and see which of the sample description atom or the magic cookie CoreMedia fills.
3. **Audio fallback codec inside fMP4 HLS** for TrueHD/DTS: test which multichannel formats AVPlayer accepts.
4. **MPVKit** packaging and licensing: an LGPL build exists (the plain `MPVKit` product, FFmpeg n9, static) and it released recently, but its README disclaims regular maintenance and points to AetherEngine for production. **Static LGPL linking** also means users must be able to relink the app with another FFmpeg, which is simplest if Nit Picker is open source (see 7).
5. **"Dolby Vision" naming in the UI:** same trademark concern as Atmos. **Decided in 1.9: keep "Dolby Vision"**, as a descriptive name of the format (the info panel adds the profile, e.g. "Dolby Vision 8.1"). It is written once, in `HDRFormat.badge`, so switching to a neutral label such as "DV" is a one-line change. "Dolby Atmos" stays out of all user-facing text (a test checks the badges and info panel).
6. **Name check:** "Nit Picker" is a common English phrase, so search the App Store, GitHub and trademark registers for clashes before shipping a release. The repo is already public under this name.
7. **License for Nit Picker itself:** **decided, MIT**, with the LGPL dependencies listed in `THIRD-PARTY-NOTICES.md` (the source is public, so the relinking duty is met). GPLv3 was rejected because it would block a future closed premium tier. Consequence: no copying of GPL code from IINA or mpv; reading it for ideas is fine.

---

## 10. Implementation notes for whoever writes the code

- Work milestone by milestone (§7) and keep the app building and runnable after each one. Commit at each milestone boundary.
- Phase 1 must not depend on any third-party code.
- Keep all AVFoundation specifics inside `Engine/AVFoundation/` and `Media/`. The UI talks only to `PlayerModel`.
- Use `@Observable` (not `ObservableObject`), `async`/`await` with AVFoundation's async `load(...)` APIs, and `@MainActor` for UI-touching types.
- When an API in this plan is marked *verify*, check the current Apple docs or headers before relying on it. If reality differs from this plan, update this file in the same commit.
- **Callbacks the system runs on its own queue** (MediaPlayer artwork and remote-command handlers, and the like) must be built in a `nonisolated` function. A closure written inside a `@MainActor` method is main-actor-isolated, and Swift 6 traps with a dispatch assertion when the system calls it from another queue. Tests that use fake services can't catch this, so check such paths by launching the real app. (`SystemNowPlaying.makeArtwork` and `.handler` follow this rule, and a test calls the artwork handler off the main thread.)
- Build and test from the command line:
  ```bash
  xcodegen generate
  xcodebuild -scheme NitPicker -destination 'platform=macOS' build
  xcodebuild -scheme NitPicker -destination 'platform=macOS' test
  ```
