import Foundation
import Testing
@testable import NitPicker

/// A generated MKV and the MP4 it came from, removed when `cleanUp` is called.
private struct Clip {
    let mkv: URL
    private let source: URL

    init(seconds: Int = 14, flavor: TestVideo.Flavor = .sdrH264, audio: [String] = ["eng", "fra"], options: MKVFixture.Options = .init()) async throws {
        source = try await TestVideo.make(seconds: seconds, fps: 10, flavor: flavor, audioLanguages: audio)
        mkv = try MKVFixture.make(from: source, options: options)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: mkv)
    }
}

@Suite struct SegmentMuxerTests {
    /// Presentation time of a track's first sample after the shared init's edit list is applied, in seconds.
    private func presentation(of timing: MP4Boxes.FragmentTiming, info: MP4Boxes.InitInfo) -> Double {
        let ticks = timing.baseDecodeTime + timing.firstCompositionOffset - info.mediaTime(track: timing.track) + info.emptyEditTicks(track: timing.track)
        return Double(ticks) / Double(info.tracks[timing.track].timescale)
    }

    @Test func cutsSegmentsThatLandOnTheirPlaceInTheTimeline() async throws {
        let clip = try await Clip(seconds: 12)
        defer { clip.cleanUp() }
        let probe = try await MKVProbe.probe(url: clip.mkv)
        let segments = SegmentPlanner.plan(keyframes: probe.keyframes, duration: probe.duration, target: .seconds(4))
        #expect(segments.count == 3)

        let muxer = try await SegmentMuxer.open(path: clip.mkv.path, video: probe.video[0], audio: probe.audio[0], segments: segments)
        defer { muxer.close() }
        let info = try #require(MP4Boxes.initInfo(muxer.initSegment))
        #expect(info.tracks.count == 2)
        #expect(info.tracks.map(\.trackID) == [1, 2])
        #expect(MP4Boxes.children(of: muxer.initSegment).map(\.type) == ["ftyp", "moov"])

        // Out of order on purpose: each segment is cut independently, whatever was cut before.
        for index in [2, 0, 1] {
            let data = Array(try await muxer.segment(index))
            let timings = MP4Boxes.firstFragmentTiming(data, trackIDs: info.tracks.map(\.trackID))
            #expect(timings.count == 2, "segment \(index) should carry both tracks")
            let start = segments[index].start.seconds
            for timing in timings {
                let shown = presentation(of: timing, info: info)
                // The video starts exactly on the keyframe; audio on the first frame at or after it (one AAC frame, ~23 ms).
                #expect(abs(shown - start) < (timing.track == 0 ? 0.02 : 0.06), "segment \(index) track \(timing.track): \(shown) vs \(start)")
            }
            #expect(MP4Boxes.children(of: data).first?.type == "moof")
            let sequence = MP4Boxes.children(of: data).first.map { MP4Boxes.u32(data, MP4Boxes.child("mfhd", of: $0, in: data)!.payload + 4) }
            #expect(sequence == index * 1000 + 1)
        }
    }

    @Test func servesRepeatedRequestsFromTheCacheAndRejectsBadIndexes() async throws {
        let clip = try await Clip(seconds: 8)
        defer { clip.cleanUp() }
        let probe = try await MKVProbe.probe(url: clip.mkv)
        let segments = SegmentPlanner.plan(keyframes: probe.keyframes, duration: probe.duration, target: .seconds(3))
        let muxer = try await SegmentMuxer.open(path: clip.mkv.path, video: probe.video[0], audio: probe.audio[0], segments: segments)
        defer { muxer.close() }

        let first = try await muxer.segment(1)
        #expect(try await muxer.segment(1) == first)
        // Many requests at once come out whole and unmixed.
        let all = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<6 { group.addTask { try await muxer.segment(1) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(all.allSatisfy { $0 == first })
        await #expect(throws: SegmentMuxer.Failure.self) { _ = try await muxer.segment(99) }
        await #expect(throws: SegmentMuxer.Failure.self) { _ = try await muxer.segment(-1) }
    }

    @Test func worksOnAFileWithoutAudio() async throws {
        let clip = try await Clip(seconds: 6, audio: [])
        defer { clip.cleanUp() }
        let probe = try await MKVProbe.probe(url: clip.mkv)
        let segments = SegmentPlanner.plan(keyframes: probe.keyframes, duration: probe.duration, target: .seconds(3))
        let muxer = try await SegmentMuxer.open(path: clip.mkv.path, video: probe.video[0], audio: nil, segments: segments)
        defer { muxer.close() }
        #expect(MP4Boxes.initInfo(muxer.initSegment)?.tracks.count == 1)
        #expect(try await muxer.segment(0).count > 0)
    }

    @Test func failsClearlyForAMissingFile() async {
        let video = ProbedStream(id: 0, kind: .video, codec: "h264")
        let segments = [SegmentSpec(index: 0, start: .zero, end: nil, duration: .seconds(5))]
        await #expect(throws: SegmentMuxer.Failure.self) {
            _ = try await SegmentMuxer.open(path: "/definitely/not/here.mkv", video: video, audio: nil, segments: segments)
        }
    }

    @Test func closingDoesNotWaitForACutAndLaterRequestsFail() async throws {
        let clip = try await Clip(seconds: 8)
        defer { clip.cleanUp() }
        let probe = try await MKVProbe.probe(url: clip.mkv)
        let segments = SegmentPlanner.plan(keyframes: probe.keyframes, duration: probe.duration, target: .seconds(3))
        let muxer = try await SegmentMuxer.open(path: clip.mkv.path, video: probe.video[0], audio: probe.audio[0], segments: segments)
        // Stands in for a long cut (a slow disk, audio being converted): the queue is busy for a while.
        muxer.queueForTesting.async { Thread.sleep(forTimeInterval: 0.3) }
        let started = ContinuousClock.now
        muxer.close()
        let took = ContinuousClock.now - started
        #expect(took < .milliseconds(100), "close returns without waiting for the queue (took \(took))")
        await #expect(throws: SegmentMuxer.Failure.self) { _ = try await muxer.segment(1) }
        await #expect(throws: SegmentMuxer.Failure.self) { _ = try await muxer.stillClip(at: .zero) }
    }
}

@MainActor
@Suite struct RemuxPlaybackTests {
    private func player(preferences: Preferences = TestPreferences.make()) -> PlayerModel {
        PlayerModel(services: .testing(preferences: preferences))
    }

    @Test func playsAnMKVAcrossSegmentsAndSeeks() async throws {
        let clip = try await Clip(seconds: 14)
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }

        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.errorMessage == nil)
        await waitUntil("duration") { model.duration.seconds > 10 }
        #expect(abs(model.duration.seconds - 14) < 0.5)
        #expect(model.mediaInfo?.container == "MKV")
        #expect(model.mediaInfo?.engineName == "AVFoundation (remuxed)")
        #expect(model.mediaInfo?.videoCodec == "H.264")
        #expect(model.mediaInfo?.resolution == CGSize(width: 320, height: 240))
        #expect(model.audioTracks.count == 2)

        // Into the second segment (it starts at 6 s) and across the boundary.
        model.seek(to: .seconds(5), precise: true)
        await waitUntil("seek to 5 s") { model.currentTime.seconds >= 5 }
        await waitUntil("playing past the boundary", timeout: .seconds(15)) { model.currentTime.seconds > 6.8 }
        #expect(model.state == .playing)

        model.seek(to: .seconds(13), precise: true)
        await waitUntil("the end", timeout: .seconds(15)) { model.state == .ended }
    }

    @Test func picksTheAudioTrackFromTheRememberedLanguage() async throws {
        let clip = try await Clip(seconds: 6)
        defer { clip.cleanUp() }
        let preferences = TestPreferences.make()
        preferences.audioLanguage = "fr"
        let model = player(preferences: preferences)
        defer { model.close() }

        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.audioTracks.count == 2)
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "fr"))
    }

    @Test func fallsBackToTheFirstAudioTrack() async throws {
        let clip = try await Clip(seconds: 6)
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(LanguageMatching.matches(model.selectedAudio?.language, "en"))
    }

    @Test func carriesChaptersAndTheirNamesFromTheFile() async throws {
        let clip = try await Clip(seconds: 8, options: .init(chapters: [("Opening", 0), ("Middle", 3), ("End", 6)]))
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing && model.mediaInfo != nil }
        #expect(model.chapters.map(\.title) == ["Opening", "Middle", "End"])
        #expect(model.chapters.map { $0.start.seconds } == [0, 3, 6])
    }

    @Test func reportsHDR10FromTheRemuxedStream() async throws {
        let clip = try await Clip(seconds: 6, flavor: .hdr10HEVC, audio: ["eng"])
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.mediaInfo?.hdr == .hdr10)
        #expect(model.mediaInfo?.videoCodec == "HEVC")
        #expect(model.formatBadges.contains("HDR10"))
    }

    @Test func carriesTheDolbyVisionRecordThroughToTheInfoPanel() async throws {
        let clip = try await Clip(seconds: 6, flavor: .hdr10HEVC, audio: ["eng"], options: .init(dolbyVision: (profile: 8, compatibilityID: 1)))
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("media info", timeout: .seconds(15)) { model.mediaInfo != nil }
        #expect(model.mediaInfo?.hdr == .dolbyVision(profile: 8, compatibilityID: 1))
        #expect(model.mediaInfo?.hdr.detailName == "Dolby Vision 8.1")
    }

    @Test func playsAFileWithoutAudio() async throws {
        let clip = try await Clip(seconds: 6, audio: [])
        defer { clip.cleanUp() }
        let model = player()
        defer { model.close() }
        model.open(clip.mkv)
        await waitUntil("playback", timeout: .seconds(15)) { model.state == .playing }
        #expect(model.errorMessage == nil)
        #expect(model.audioTracks.isEmpty)
    }

    @Test func reportsAFileThatIsNotReallyMatroska() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-junk-\(UUID().uuidString).mkv")
        try Data("not a matroska file".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        let model = player()
        defer { model.close() }
        model.open(junk)
        await waitUntil("an error") { model.errorMessage != nil }
        #expect(model.errorMessage?.hasPrefix("This file can't be read") == true)
        #expect(model.state != .playing)
    }

    @Test func switchingBetweenAnMKVAndAnMP4Works() async throws {
        let clip = try await Clip(seconds: 6)
        let mp4 = try await TestVideo.make(seconds: 3)
        defer { clip.cleanUp(); try? FileManager.default.removeItem(at: mp4) }
        let model = player()
        defer { model.close() }

        model.open(clip.mkv)
        await waitUntil("the MKV", timeout: .seconds(15)) { model.state == .playing && model.mediaInfo?.container == "MKV" }
        model.open(mp4)
        await waitUntil("the MP4", timeout: .seconds(15)) { model.state == .playing && model.mediaInfo?.container == "MP4" }
        #expect(model.errorMessage == nil)
    }
}

@Suite struct EngineRoutingTests {
    @Test func sendsMatroskaAndWebMToTheRemuxEngine() {
        for ext in ["mkv", "MKV", "webm", "mka"] { #expect(EngineRouter.route(forExtension: ext) == .remux) }
    }

    @Test func keepsTheRestWhereTheyWere() {
        for ext in ["mp4", "mov", "m4v", "m3u8"] { #expect(EngineRouter.route(forExtension: ext) == .avFoundation) }
        for ext in ["avi", "wmv", "flv"] { #expect(EngineRouter.route(forExtension: ext) == .compatibility) }
    }
}
