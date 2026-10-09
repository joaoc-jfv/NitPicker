import CoreGraphics
import Foundation
import Network
import Testing
@testable import NitPicker

@Suite struct MPVMappingTests {
    @Test func buildsTracksFromMPVsList() throws {
        let audio = MPVMapping.TrackFields(id: 2, type: "audio", language: "eng", title: "Commentary", codec: "dts", channels: 6, isDefault: true)
        let track = try #require(MPVMapping.mediaTrack(audio))
        #expect(track.id == "audio-2" && track.kind == .audio)
        #expect(track.language == "en" && track.title == "Commentary" && track.codec == "DTS" && track.channels == 6)
        #expect(track.isDefault && !track.isForced && !track.isSpatial)
        #expect(MPVMapping.mpvID(of: track) == 2)

        let subtitle = MPVMapping.TrackFields(id: 5, type: "sub", language: "fre", codec: "hdmv_pgs_subtitle", isForced: true)
        let sub = try #require(MPVMapping.mediaTrack(subtitle))
        #expect(sub.id == "subtitle-5" && sub.kind == .subtitle && sub.language == "fr" && sub.codec == "PGS" && sub.isForced)
        #expect(sub.channels == nil)

        #expect(MPVMapping.mediaTrack(MPVMapping.TrackFields(id: 1, type: "video")) == nil)
        #expect(MPVMapping.mediaTrack(MPVMapping.TrackFields(id: 1, type: "audio", channels: 0))?.channels == nil)
    }

    @Test func mapsColourNamesToTheOnesTheInfoPanelKnows() {
        #expect(MPVMapping.hdr(gamma: "pq") == .hdr10)
        #expect(MPVMapping.hdr(gamma: "hlg") == .hlg)
        #expect(MPVMapping.hdr(gamma: "bt.1886") == .sdr)
        #expect(MPVMapping.hdr(gamma: nil) == .sdr)
        #expect(MPVMapping.ffmpegPrimaries("bt.2020") == "bt2020")
        #expect(MPVMapping.ffmpegPrimaries("display-p3") == "smpte432")
        #expect(MPVMapping.ffmpegTransfer("pq") == "smpte2084")
        #expect(MPVMapping.ffmpegTransfer("hlg") == "arib-std-b67")
        #expect(MPVMapping.ffmpegPrimaries(nil) == nil)
        // The panel's own wording comes out of the existing mapping.
        #expect(ColorDescription.primaries(ColorDescription.coreMediaPrimaries(fromFFmpeg: MPVMapping.ffmpegPrimaries("bt.2020"))) == "BT.2020")
    }

    @Test func understandsTheBibliographicLanguageCodesMatroskaAndAVIUse() {
        for (code, alpha2) in [("fre", "fr"), ("ger", "de"), ("chi", "zh"), ("dut", "nl"), ("gre", "el"), ("eng", "en"), ("ita", "it"), ("fra", "fr")] {
            #expect(LanguageMatching.primaryLanguage(code) == alpha2, "\(code)")
        }
        #expect(LanguageMatching.matches("fre", "fr") && LanguageMatching.matches("fra", "fre"))
    }

    @Test func namesContainersShortly() {
        #expect(MPVMapping.containerName("matroska,webm") == "MKV")
        #expect(MPVMapping.containerName("avi") == "AVI")
        #expect(MPVMapping.containerName("mov,mp4,m4a,3gp,3g2,mj2") == "MOV")
        #expect(MPVMapping.containerName(nil) == "")
    }

    @Test func startsWithHDRPassthroughOnlyWhenTheDisplayCanShowIt() {
        func value(_ key: String, hdr: Bool) -> String? { MPVEngine.options(hdr: hdr, audioLanguage: nil).first { $0.0 == key }?.1 }
        #expect(value("target-colorspace-hint", hdr: true) == "yes")
        #expect(value("target-colorspace-hint", hdr: false) == "no")
        #expect(value("sub-auto", hdr: true) == "no")  // the app finds sidecar subtitles itself
        #expect(MPVEngine.options(hdr: false, audioLanguage: "fr").contains { $0.0 == "alang" && $0.1 == "fr" })
    }

    @Test func mapsTheSubtitleStyleToMPVsProperties() {
        func properties(_ style: SubtitleStyle) -> [String: String] { Dictionary(uniqueKeysWithValues: MPVMapping.subtitleProperties(for: style)) }
        var style = SubtitleStyle()
        style.size = .medium
        style.background = .shadow
        #expect(properties(style)["sub-font-size"] == "32")  // 4.5% of a 720-high picture
        #expect(properties(style)["sub-border-style"] == "outline-and-shadow")
        #expect(properties(style)["sub-shadow-offset"] == "1.5")
        style.size = .extraLarge
        #expect(properties(style)["sub-font-size"] == "52")
        style.background = .box
        #expect(properties(style)["sub-border-style"] == "background-box")
        #expect(properties(style)["sub-back-color"] == "#B8000000")
        style.background = .none
        #expect(properties(style)["sub-border-size"] == "0" && properties(style)["sub-shadow-offset"] == "0")
    }

    @Test func placesSubtitlesAboveTheBottomEdge() {
        #expect(MPVMapping.subtitlePosition(lift: 0.06) == 97)  // the app's default: 6% up, mpv's own margin is about 3%
        #expect(MPVMapping.subtitlePosition(lift: 0.16) == 87)
        #expect(MPVMapping.subtitlePosition(lift: -0.2) == 123)
        #expect(MPVMapping.subtitlePosition(lift: 5) == 0)
        #expect(MPVMapping.subtitlePosition(lift: -9) == 150)
    }

    @Test func softensMPVsErrorsForTheUser() {
        #expect(MPVEngine.friendly("unrecognized file format") == "This file can't be played.")
        #expect(MPVEngine.friendly("loading failed") == "This file can't be played (loading failed).")
    }

    @Test func displaysCodecNamesForWhatLegacyFilesCarry() {
        #expect(CodecNames.displayName(forFFmpegCodec: "mpeg4") == "MPEG-4")
        #expect(CodecNames.displayName(forFFmpegCodec: "vp9") == "VP9")
        #expect(CodecNames.displayName(forFFmpegCodec: "truehd") == "TrueHD")
        #expect(CodecNames.displayName(forFFmpegCodec: "pcm_s24le") == "PCM")
        #expect(CodecNames.displayName(forFFmpegCodec: "unknowncodec") == "UNKNOWNCODEC")
    }
}

@MainActor
@Suite struct MPVPlaybackTests {
    private func player() -> PlayerModel {
        PlayerModel(services: .testing())
    }

    @Test func playsAFileTheOtherEnginesRefuseAndFindsItsWayThroughIt() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 6)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = player()
        defer { model.close() }

        model.open(file)  // Matroska, so the remuxer refuses the MPEG-4 and libmpv takes over
        await waitUntil("playback", timeout: .seconds(20)) { model.state == .playing }
        #expect(model.errorMessage == nil)
        await waitUntil("media info") { model.mediaInfo?.videoCodec != nil }
        #expect(model.mediaInfo?.engineName == "mpv (compatibility mode)")
        #expect(model.mediaInfo?.container == "MKV")
        #expect(model.mediaInfo?.videoCodec == "MPEG-4")
        #expect(model.mediaInfo?.resolution == CGSize(width: 320, height: 240))
        await waitUntil("duration") { abs(model.duration.seconds - 6) < 0.5 }
        await waitUntil("time moving", timeout: .seconds(10)) { model.currentTime.seconds > 1 }

        model.pause()
        await waitUntil("paused") { model.state == .paused }
        model.seek(to: .seconds(4), precise: true)
        await waitUntil("the seek") { abs(model.livePlaybackTime().seconds - 4) < 0.3 }
        model.play()
        await waitUntil("the end", timeout: .seconds(15)) { model.state == .ended }
        #expect(model.errorMessage == nil)
    }

    @Test func playsAnMPEGTransportStreamAVFoundationCannotOpen() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 3, container: "mpegts", fileExtension: "ts")
        defer { try? FileManager.default.removeItem(at: file) }
        let model = player()
        defer { model.close() }
        model.open(file)
        await waitUntil("playback", timeout: .seconds(12)) { model.state == .playing }
        #expect(model.state == .playing, "state \(model.state), engine \(String(describing: model.mediaInfo?.engineName)), error \(String(describing: model.errorMessage))")
        #expect(model.errorMessage == nil)
        #expect(model.mediaInfo?.engineName == "mpv (compatibility mode)")
    }

    @Test func reportsAFileLibmpvCannotOpenEither() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-junk-\(UUID().uuidString).avi")
        try Data("not a video at all".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let model = player()
        defer { model.close() }
        model.open(junk)
        await waitUntil("an error", timeout: .seconds(15)) { model.errorMessage != nil }
        #expect(model.errorMessage?.hasPrefix("This file can't be played") == true)
    }
}

@MainActor
@Suite struct MPVSubtitleTests {
    private static let ass = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 384
    PlayResY: 288

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.50,0:00:02.50,Default,,0,0,0,,{\\i1}Styled{\\i0} line
    """

    private func loadedEngine() async throws -> (MPVEngine, URL) {
        let file = try LegacyFixture.makeMPEG4(seconds: 4)
        let engine = MPVEngine()
        try await engine.load(file, startAt: nil)
        return (engine, file)
    }

    @Test func mpvAcceptsEveryStylePropertyTheAppSends() async throws {
        let (engine, file) = try await loadedEngine()
        defer { engine.close(); try? FileManager.default.removeItem(at: file) }
        let handle = try #require(engine.handleForTesting)
        for size in SubtitleStyle.Size.allCases {
            for background in SubtitleStyle.Background.allCases {
                var style = SubtitleStyle()
                style.size = size
                style.background = background
                for (name, value) in MPVMapping.subtitleProperties(for: style) {
                    #expect(handle.set(name, string: value), "mpv refused \(name)=\(value)")
                }
            }
        }
        for lift in [-0.05, 0.06, 0.25] {
            #expect(handle.set("sub-pos", string: "\(MPVMapping.subtitlePosition(lift: lift))"))
        }
        engine.setSubtitleStyle(SubtitleStyle())
        engine.setSubtitleLift(0.16)
        #expect(handle.double("sub-pos") == 87)
        #expect(handle.double("sub-font-size") == 32)
    }

    @Test func addsAnAssFileAsATrackSelectsItAndShiftsIt() async throws {
        let (engine, file) = try await loadedEngine()
        let sidecar = file.deletingPathExtension().appendingPathExtension("en.ass")
        try Self.ass.write(to: sidecar, atomically: true, encoding: .utf8)
        defer { engine.close(); try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: sidecar) }

        #expect(engine.subtitleTracks.isEmpty)
        let track = try #require(engine.addExternalSubtitle(sidecar, title: "English", language: "en"))
        #expect(track.kind == .subtitle && track.title == "English" && track.language == "en" && track.codec == "ASS")
        #expect(engine.subtitleTracks == [track])
        engine.selectSubtitle(nil)
        // Adding the same file again reuses the track.
        _ = engine.addExternalSubtitle(sidecar, title: "English", language: "en")
        #expect(engine.subtitleTracks.count == 1)

        engine.selectSubtitle(track)
        #expect(engine.selectedSubtitleTrack?.id == track.id)
        engine.setSubtitleDelay(.milliseconds(500))
        #expect(engine.handleForTesting?.double("sub-delay") == 0.5)
        #expect(engine.drawsSubtitlesNatively)
        #expect(engine.addExternalSubtitle(URL(fileURLWithPath: "/nonexistent/none.ass"), title: nil, language: nil) == nil)
    }
}

@MainActor
@Suite struct MPVThumbnailTests {
    @Test func fitsAPictureIntoTheRequestedBoxWithItsPixelAspectApplied() {
        func fit(_ width: Int, _ height: Int, _ aspect: Double = 1, _ box: CGSize) -> [Int] {
            let size = MPVThumbnailer.fittedSize(width: width, height: height, pixelAspect: aspect, maxSize: box)
            return [size.width, size.height]
        }
        #expect(fit(3840, 2160, 1, CGSize(width: 320, height: 180)) == [320, 180])
        #expect(fit(320, 240, 1, CGSize(width: 640, height: 640)) == [320, 240], "never larger than the source")
        #expect(fit(720, 480, 32.0 / 27.0, CGSize(width: 640, height: 640)) == [640, 360], "anamorphic DVD: 720×480 shows as 16:9")
        #expect(fit(1000, 100, 1, CGSize(width: 100, height: 100)) == [100, 10])
        #expect(fit(1, 1, 0, CGSize(width: 100, height: 100)) == [2, 2], "a missing pixel aspect counts as square")
    }

    @Test func makesAStillFromALegacyFileThatMPVPlays() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 6)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        try await engine.load(file, startAt: nil)
        defer { engine.close() }

        let image = try #require(await engine.thumbnail(at: .seconds(3), maxSize: CGSize(width: 160, height: 160)))
        #expect(image.width == 160 && image.height == 120)

        // The clip is a moving gradient, so a real picture has many different values, and two moments differ.
        func signature(_ image: CGImage) -> [UInt8] {
            let data = image.dataProvider!.data! as Data
            return stride(from: 0, to: data.count, by: 4 * 37).map { data[$0] }
        }
        let first = signature(image)
        #expect(Set(first).count > 20)
        let later = try #require(await engine.thumbnail(at: .seconds(5), maxSize: CGSize(width: 160, height: 160)))
        #expect(signature(later) != first)
        // Past the end still gives the last keyframe's picture rather than failing.
        #expect(await engine.thumbnail(at: .seconds(600), maxSize: CGSize(width: 160, height: 160)) != nil)
    }

    @Test func aCancelledRequestGivesNothingAndAFileWithNoPictureGivesNothing() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-nothumb-\(UUID().uuidString).mkv")
        try Data("not a video".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let thumbnailer = MPVThumbnailer(path: junk.path)
        #expect(await thumbnailer.thumbnail(at: .seconds(1), maxSize: CGSize(width: 100, height: 100)) == nil)
        thumbnailer.close()
    }

    @Test func scrubPreviewsAndArtworkWorkThroughTheModel() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 6)
        defer { try? FileManager.default.removeItem(at: file) }
        let model = PlayerModel(services: .testing())
        defer { model.close() }
        model.open(file)
        await waitUntil("playback", timeout: .seconds(20)) { model.state == .playing }
        await waitUntil("duration") { model.duration.seconds > 5 }
        model.updateScrubPreview(fraction: 0.5)
        await waitUntil("the preview picture") { model.scrubPreview?.image != nil }
        #expect(model.scrubThumbnailsAvailable)
    }
}

@MainActor
@Suite struct MPVDolbyVisionNoteTests {
    @Test func theNoteExplainsAToneMappedDolbyVisionSource() {
        let note = MPVMapping.hdrNote(source: .dolbyVision(profile: 8, compatibilityID: 1), shown: .hdr10)
        #expect(note?.hasPrefix("Dolby Vision 8.1 source, tone-mapped to HDR10") == true)
        #expect(MPVMapping.hdrNote(source: .hdr10, shown: .hdr10) == nil)
        #expect(MPVMapping.hdrNote(source: nil, shown: .sdr) == nil)
        let rows = InfoSections.build(
            fileName: "a.mkv", info: MediaInfo(container: "MKV", engineName: "mpv (compatibility mode)", hdr: .hdr10, hdrNote: note),
            audio: nil, outputMode: .spatial, isHDRPlaybackEligible: true, rate: 1
        ).first { $0.title == "HDR" }?.rows
        #expect(rows?.contains { $0.label == "Note" } == true)

        // No system spatialization on this engine: the panel doesn't claim any.
        let track = MediaTrack(id: "audio-1", kind: .audio, language: "it", title: nil, codec: "E-AC-3", channels: 6, isDefault: true, isForced: false, isSpatial: false)
        func audio(_ available: Bool) -> [InfoRow] {
            InfoSections.build(
                fileName: "a.mkv", info: MediaInfo(container: "MKV", engineName: "x"), audio: track, outputMode: .spatial,
                isHDRPlaybackEligible: true, rate: 1, spatialAudioAvailable: available
            ).first { $0.title == "Audio" }?.rows ?? []
        }
        #expect(audio(true).contains { $0.label == "Spatial Audio track" } && audio(true).first { $0.label == "Output" }?.value == "Spatial Audio")
        #expect(!audio(false).contains { $0.label == "Spatial Audio track" } && audio(false).first { $0.label == "Output" }?.value == "Original channels")
    }

    @Test func readsTheDolbyVisionProfileFromTheFileAndShowsItInTheInfo() async throws {
        let video = try await TestVideo.make(seconds: 3)
        let file = try MKVFixture.make(from: video, options: .init(dolbyVision: (profile: 8, compatibilityID: 1)))
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: file) }
        #expect(MPVSourceProbe.hdrFormat(atPath: file.path) == .dolbyVision(profile: 8, compatibilityID: 1))
        #expect(MPVSourceProbe.hdrFormat(atPath: video.path) == .sdr)
        #expect(MPVSourceProbe.hdrFormat(atPath: "/nonexistent.mkv") == nil)

        // mpv plays the file; the engine adds the note once libavformat has read the record.
        let engine = MPVEngine()
        defer { engine.close() }
        var note: String?
        let listener = Task { @MainActor in
            for await event in engine.events {
                if case .mediaInfoChanged(let info) = event, let found = info.hdrNote { note = found; break }
            }
        }
        try await engine.load(file, startAt: nil)
        await waitUntil("the note") { note != nil }
        listener.cancel()
        #expect(note?.contains("Dolby Vision 8.1") == true)
    }
}

/// Draws a frame with and without a subtitle and compares them, so a style that mpv accepts but never shows would be caught.
@MainActor
@Suite struct MPVSubtitleRenderingTests {
    private func differingPixels(_ a: MPVHandle.RawFrame, _ b: MPVHandle.RawFrame) -> Int {
        guard a.width == b.width, a.height == b.height else { return -1 }
        var count = 0
        for row in 0..<a.height {
            for column in 0..<a.width {
                let offset = row * a.stride + column * 4
                if a.bytes[offset] != b.bytes[offset] || a.bytes[offset + 1] != b.bytes[offset + 1] || a.bytes[offset + 2] != b.bytes[offset + 2] { count += 1 }
            }
        }
        return count
    }

    private func frame(_ engine: MPVEngine) async throws -> MPVHandle.RawFrame {
        // The renderer needs a moment after a change before the next frame carries it.
        try await Task.sleep(for: .milliseconds(400))
        let handle = try #require(engine.handleForTesting)
        return try #require(handle.screenshotRaw("subtitles"), "no frame: \(engine.lastErrorLog ?? "")")
    }

    @Test func libassDrawsAStyledAssLineAndTheUsersStyleChangesHowBigPlainTextIs() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 5)
        let assFile = file.deletingPathExtension().appendingPathExtension("ass")
        let srtFile = file.deletingPathExtension().appendingPathExtension("srt")
        try MPVSubtitleTests.assForRendering.write(to: assFile, atomically: true, encoding: .utf8)
        try "1\n00:00:00,500 --> 00:00:04,500\nHello plain text\n".write(to: srtFile, atomically: true, encoding: .utf8)
        let engine = MPVEngine()
        try await engine.load(file, startAt: nil)
        defer {
            engine.close()
            for url in [file, assFile, srtFile] { try? FileManager.default.removeItem(at: url) }
        }
        let ass = try #require(engine.addExternalSubtitle(assFile, title: "ASS", language: "en"))
        let srt = try #require(engine.addExternalSubtitle(srtFile, title: "SRT", language: "en"))

        await engine.seek(to: .seconds(2), precise: true)
        engine.selectSubtitle(nil)
        let bare = try await frame(engine)
        engine.selectSubtitle(ass)
        let withASS = try await frame(engine)
        let assPixels = differingPixels(bare, withASS)
        #expect(assPixels > 500, "the styled line should change the picture, changed \(assPixels)")

        // Plain text follows the user's size: extra large covers more pixels than small.
        engine.selectSubtitle(srt)
        var style = SubtitleStyle()
        style.size = .small
        style.background = .none
        engine.setSubtitleStyle(style)
        let small = try await frame(engine)
        style.size = .extraLarge
        engine.setSubtitleStyle(style)
        let large = try await frame(engine)
        let smallPixels = differingPixels(bare, small), largePixels = differingPixels(bare, large)
        #expect(smallPixels > 100 && largePixels > smallPixels * 2, "small \(smallPixels), extra large \(largePixels)")

        // A box behind the text covers more than the text alone.
        style.size = .medium
        style.background = .none
        engine.setSubtitleStyle(style)
        let plain = try await frame(engine)
        style.background = .box
        engine.setSubtitleStyle(style)
        let boxed = try await frame(engine)
        #expect(differingPixels(bare, boxed) > differingPixels(bare, plain) * 3 / 2, "box \(differingPixels(bare, boxed)), plain \(differingPixels(bare, plain))")

        // Lifting the subtitles moves them up the picture.
        func lowestChangedRow(_ other: MPVHandle.RawFrame) -> Int {
            (0..<bare.height).last { row in (0..<bare.width).contains { column in bare.bytes[row * bare.stride + column * 4 + 1] != other.bytes[row * bare.stride + column * 4 + 1] } } ?? -1
        }
        engine.setSubtitleLift(0.06)
        let low = try await frame(engine)
        engine.setSubtitleLift(0.35)
        let high = try await frame(engine)
        #expect(lowestChangedRow(high) < lowestChangedRow(low) - 20, "low \(lowestChangedRow(low)), high \(lowestChangedRow(high)) of \(bare.height)")
    }
}

extension MPVSubtitleTests {
    static let assForRendering = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 320
    PlayResY: 240

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,28,&H0000FFFF,&H000000FF,&H00000000,&H00000000,1,0,0,0,100,100,0,0,1,2,2,5,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.50,0:00:04.50,Default,,0,0,0,,Styled yellow centre text
    """
}

@MainActor
@Suite struct MPVChapterTests {
    @Test func listsChaptersAndTheModelNavigatesThem() async throws {
        let video = try await TestVideo.make(seconds: 40)
        let file = try MKVFixture.make(from: video, options: .init(chapters: [("Opening", 0), ("Middle", 3), ("End", 6)]))
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: file) }
        // The remuxer would take this file; the compatibility engine is asked for directly.
        let model = PlayerModel(services: .testing(), engineFactory: { _ in MPVEngine() })
        defer { model.close() }
        model.open(file)
        await waitUntil("chapters", timeout: .seconds(15)) { model.chapters.count == 3 }
        #expect(model.chapters.map(\.title) == ["Opening", "Middle", "End"])
        #expect(model.chapters.map { Int($0.start.seconds.rounded()) } == [0, 3, 6])
        #expect(model.mediaInfo?.engineName == "mpv (compatibility mode)")

        await waitUntil("playing") { model.state == .playing }
        model.pause()
        await waitUntil("paused") { model.state == .paused }
        #expect(model.state == .paused, "state \(model.state)")
        let next = model.nextChapter()
        #expect(next?.title == "Middle")
        await waitUntil("the jump") { abs(model.livePlaybackTime().seconds - 3) < 0.3 }
        #expect(model.currentChapter?.title == "Middle")
        #expect(model.previousChapter()?.title == "Opening")
    }
}

@MainActor
@Suite struct MPVResizeTests {
    @Test func theVideoOutputFollowsTheViewWhenItIsResizedAfterLoading() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 20)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        let view = try #require(engine.videoView as? MPVVideoView)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.layout()
        try await engine.load(file, startAt: nil)
        defer { engine.close() }
        engine.play()
        let handle = try #require(engine.handleForTesting)
        await waitUntil("the first frame") { (handle.int("osd-dimensions/w") ?? 0) > 0 }
        let before = view.metalLayer.drawableSize
        #expect(handle.int("osd-dimensions/w") == Int(before.width))

        // The window grows to fit the video once its size is known; mpv must lay the picture out for the new size.
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        view.layout()
        let after = view.metalLayer.drawableSize
        #expect(after != before)
        await waitUntil("mpv to measure again", timeout: .seconds(8)) {
            handle.int("osd-dimensions/w") == Int(after.width) && handle.int("osd-dimensions/h") == Int(after.height)
        }
        // Playback carries on from where it was.
        let position = handle.double("time-pos") ?? 0
        await waitUntil("time to move") { (handle.double("time-pos") ?? 0) > position + 0.3 }
        #expect(engine.currentTime.seconds > position)
    }
}

@MainActor
@Suite struct VideoAdjustmentsTests {
    @Test func clampsToMPVsScaleAndNamesItsProperties() {
        let wild = VideoAdjustments(brightness: 400, contrast: -400, saturation: 7).clamped()
        #expect(wild == VideoAdjustments(brightness: 100, contrast: -100, saturation: 7))
        #expect(VideoAdjustments().isDefault && !wild.isDefault)
        #expect(wild.mpvProperties.map(\.name) == ["brightness", "contrast", "saturation"])
    }

    @Test func onlyTheCompatibilityEngineOffersThemAndTheModelSaysWhyOtherwise() async {
        let plain = FakeEngine()
        let player = PlayerModel(services: .testing(), engineFactory: { _ in plain })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        #expect(!player.supportsVideoAdjustments)
        player.showAdjustmentsPanel()
        #expect(player.activePanel == nil && player.toast?.text == "Picture adjustments need the Compatibility Engine")
    }

    @Test func theModelHandsThemToTheEngineKeepsThemForTheFileAndResetsThemForTheNextOne() async {
        var made: [FakeEngine] = []
        let player = PlayerModel(services: .testing(), engineFactory: { _ in
            let fresh = FakeEngine()
            fresh.supportsVideoAdjustments = true
            made.append(fresh)
            return fresh
        })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/film.mkv"))
        await waitUntil("playback") { player.state == .playing }
        let engine = made[0]
        #expect(player.supportsVideoAdjustments)
        player.showAdjustmentsPanel()
        #expect(player.activePanel == .adjustments)

        player.setVideoAdjustments(VideoAdjustments(brightness: 30, contrast: 500, saturation: -20))
        #expect(player.videoAdjustments == VideoAdjustments(brightness: 30, contrast: 100, saturation: -20))
        #expect(engine.adjustments.last == player.videoAdjustments)
        let count = engine.adjustments.count
        player.setVideoAdjustments(player.videoAdjustments)
        #expect(engine.adjustments.count == count, "no change, nothing sent")
        player.resetVideoAdjustments()
        #expect(player.videoAdjustments.isDefault && engine.adjustments.last?.isDefault == true)

        player.setVideoAdjustments(VideoAdjustments(brightness: 10))
        player.open(URL(fileURLWithPath: "/Movies/other.mkv"))
        await waitUntil("the next file") { player.currentURL?.lastPathComponent == "other.mkv" && player.state == .playing }
        #expect(player.videoAdjustments.isDefault)
    }

    @Test func mpvTakesTheValuesAndKeepsThemForTheNextOpen() async throws {
        // `screenshot-raw` doesn't include the colour adjustments in this build, so the picture itself is checked in the real
        // app (PLAN.md 4.3 notes); here mpv's own state is.
        let file = try LegacyFixture.makeMPEG4(seconds: 3)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        engine.setVideoAdjustments(VideoAdjustments(brightness: 20, contrast: -30, saturation: 40))  // before loading
        try await engine.load(file, startAt: nil)
        defer { engine.close() }
        #expect(engine.supportsVideoAdjustments)
        let handle = try #require(engine.handleForTesting)
        #expect(handle.double("brightness") == 20 && handle.double("contrast") == -30 && handle.double("saturation") == 40)
        engine.setVideoAdjustments(VideoAdjustments(brightness: 500))
        #expect(handle.double("brightness") == 100, "clamped to mpv's range")
        engine.setVideoAdjustments(VideoAdjustments())
        #expect(handle.double("brightness") == 0 && handle.double("contrast") == 0 && handle.double("saturation") == 0)
    }
}

/// A local file must not make the compatibility engine reach the network: the sandbox allows outgoing connections (for the
/// loopback HLS server), so a playlist or an HLS manifest disguised as a video could otherwise call an attacker's server.
@MainActor
@Suite(.serialized) struct MPVNetworkTests {
    /// Counts the connections made to a listener on the loopback address.
    final class Tripwire: @unchecked Sendable {
        private let listener: NWListener
        private let hits = Counter()
        let port: UInt16

        init() async throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            let listener = listener, hits = hits
            port = try await withCheckedThrowingContinuation { continuation in
                let resumed = Resumed()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if resumed.take() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error), .waiting(let error): if resumed.take() { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { connection in
                    hits.increment()
                    connection.cancel()
                }
                listener.start(queue: DispatchQueue(label: "nitpicker.tests.tripwire"))
            }
        }

        var connections: Int { hits.value }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }

        private final class Resumed: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        func stop() { listener.cancel() }
    }

    private func open(_ contents: String, tripwire: Tripwire) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-reference-\(UUID().uuidString).avi")
        try Data(contents.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        defer { engine.close() }
        try? await engine.load(file, startAt: nil)
        try await Task.sleep(for: .seconds(2))
    }

    @Test func aPlaylistDisguisedAsAVideoDoesNotReachTheNetwork() async throws {
        let tripwire = try await Tripwire()
        defer { tripwire.stop() }
        try await open("#EXTM3U\nhttp://127.0.0.1:\(tripwire.port)/movie.mp4\n", tripwire: tripwire)
        #expect(tripwire.connections == 0)
    }

    @Test func anHLSManifestDisguisedAsAVideoDoesNotReachTheNetwork() async throws {
        let tripwire = try await Tripwire()
        defer { tripwire.stop() }
        let manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nhttp://127.0.0.1:\(tripwire.port)/segment.ts\n#EXT-X-ENDLIST\n"
        try await open(manifest, tripwire: tripwire)
        #expect(tripwire.connections == 0)
    }

    @Test func mpvAcceptedTheOptionsThatKeepItOffTheNetwork() async throws {
        // `MPVHandle` skips options mpv refuses, so check that these really took.
        let file = try LegacyFixture.makeMPEG4(seconds: 2)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        try await engine.load(file, startAt: nil)
        defer { engine.close() }
        let handle = try #require(engine.handleForTesting)
        #expect(handle.flag("access-references") == false)
        #expect(handle.flag("load-unsafe-playlists") == false)
        #expect(handle.string("demuxer-lavf-o")?.contains("protocol_whitelist=file") == true, "\(String(describing: handle.string("demuxer-lavf-o")))")
    }

    @Test func readingTheFileOurselvesDoesNotReachTheNetworkEither() async throws {
        // The info panel's HDR probe and the scrub thumbnails open the file with libavformat directly, outside mpv. FFmpeg's own
        // default for a local file already refuses http; `FFmpegInput` says so explicitly, and this keeps it that way.
        let tripwire = try await Tripwire()
        defer { tripwire.stop() }
        let manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nhttp://127.0.0.1:\(tripwire.port)/segment.ts\n#EXT-X-ENDLIST\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-manifest-\(UUID().uuidString).avi")
        try Data(manifest.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        _ = await Task.detached { MPVSourceProbe.hdrFormat(atPath: file.path) }.value
        _ = await MPVThumbnailer(path: file.path).thumbnail(at: .zero, maxSize: CGSize(width: 64, height: 64))
        try await Task.sleep(for: .milliseconds(500))
        #expect(tripwire.connections == 0)
    }
}
