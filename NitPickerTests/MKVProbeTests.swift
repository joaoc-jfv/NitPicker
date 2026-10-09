import FFmpegKit
import Foundation
import Testing
@testable import NitPicker

@Suite struct FFmpegLinkTests {
    @Test func linksTheLGPLBuild() {
        #expect(FFmpegInfo.version.hasPrefix("libavformat 6"))
        #expect(FFmpegInfo.license.contains("LGPL"))
        #expect(!FFmpegInfo.license.contains("GPL version 2"))
    }
}

@Suite struct FFmpegInputTests {
    @Test func turnsTimestampsIntoSecondsOnlyWhenTheyMakeSense() {
        #expect(FFmpegTimestamp.seconds(1500, timeBase: AVRational(num: 1, den: 1000)) == 1.5)
        #expect(FFmpegTimestamp.seconds(-500, timeBase: AVRational(num: 1, den: 1000)) == -0.5)
        #expect(FFmpegTimestamp.seconds(Int64.min, timeBase: AVRational(num: 1, den: 1000)) == nil, "no timestamp")
        #expect(FFmpegTimestamp.seconds(10, timeBase: AVRational(num: 0, den: 1000)) == nil)
        #expect(FFmpegTimestamp.seconds(10, timeBase: AVRational(num: 1, den: 0)) == nil)
        #expect(FFmpegTimestamp.seconds(Int64.max, timeBase: AVRational(num: 1, den: 1)) == nil, "too far to be real")
    }

    @Test func theRemuxerOpensNeitherManifestsNorConcatListsPosingAsMatroska() throws {
        for (name, contents) in [
            ("hls", "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\nsegment.ts\n#EXT-X-ENDLIST\n"),
            ("concat", "ffconcat version 1.0\nfile 'other.mkv'\n"),
        ] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-\(name)-\(UUID().uuidString).mkv")
            try Data(contents.utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: MKVProbe.Failure.self, "\(name)") { try MKVProbe.probe(path: url.path) }
        }
    }
}

@Suite struct MKVProbeTests {
    private func mp4(seconds: Int = 4, flavor: TestVideo.Flavor = .sdrH264, audio: [String] = ["eng", "fra"]) async throws -> URL {
        try await TestVideo.make(seconds: seconds, fps: 10, flavor: flavor, audioLanguages: audio)
    }

    private func mkv(_ source: URL, _ options: MKVFixture.Options = .init()) throws -> URL {
        try MKVFixture.make(from: source, options: options)
    }

    private func cleanUp(_ urls: URL...) { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

    @Test func readsTracksFromAMatroskaFile() async throws {
        let source = try await mp4()
        let url = try mkv(source)
        defer { cleanUp(source, url) }

        let result = try await MKVProbe.probe(url: url)
        #expect(result.formatName.contains("matroska"))
        #expect(abs(result.duration.seconds - 4) < 0.3)

        let video = try #require(result.video.first)
        #expect(video.codec == "h264")
        #expect(video.width == 320 && video.height == 240)
        #expect(abs((video.frameRate ?? 0) - 10) < 0.5)
        #expect(video.hdr == .sdr)

        #expect(result.audio.map(\.codec) == ["aac", "aac"])
        #expect(result.audio.map(\.language) == ["eng", "fra"])
        #expect(result.audio.map(\.channels) == [1, 1])
        #expect(result.audio.map(\.sampleRate) == [44100, 44100])
        #expect(result.subtitles.isEmpty)
        #expect(result.streams.map(\.id) == [0, 1, 2])
    }

    @Test func readsTheKeyframeIndexFromTheCues() async throws {
        let source = try await mp4(seconds: 6)
        let url = try mkv(source)
        defer { cleanUp(source, url) }

        let keyframes = try await MKVProbe.probe(url: url).keyframes
        #expect(keyframes.count >= 5)  // one a second
        #expect(keyframes.first == .zero)
        #expect(keyframes == keyframes.sorted())
        #expect(Set(keyframes.map { Int($0.seconds * 1000) }).count == keyframes.count)
        #expect(keyframes.last! < .seconds(6.2))
    }

    @Test func aFileWithoutCuesStillProbesAndNeverReportsAWrongIndex() async throws {
        let source = try await mp4(seconds: 4)
        let url = try mkv(source, .init(withoutCues: true))
        defer { cleanUp(source, url) }

        let result = try await MKVProbe.probe(url: url)
        #expect(result.video.count == 1)  // everything else still reads fine
        // A file this small is read whole while probing, so FFmpeg can index it anyway. Either way the answer
        // is empty or complete, never a stub.
        if !result.keyframes.isEmpty {
            #expect(MKVProbe.isCompleteIndex(result.keyframes, duration: result.duration))
        }
    }

    @Test func scanningFindsTheSameKeyframesAsTheCues() async throws {
        let source = try await mp4(seconds: 6)
        let url = try mkv(source)
        defer { cleanUp(source, url) }
        let indexed = try await MKVProbe.probe(url: url)
        let scanned = try await MKVProbe.scanKeyframes(url: url, videoIndex: indexed.video[0].id)
        #expect(scanned.count == indexed.keyframes.count)
        for (a, b) in zip(scanned, indexed.keyframes) { #expect(abs(a.seconds - b.seconds) < 0.002) }
    }

    @Test func aScanFindsEveryKeyframeOfAFileWithoutCues() async throws {
        let source = try await mp4(seconds: 8)
        let url = try mkv(source, .init(withoutCues: true))
        let indexedURL = try mkv(source)
        defer { cleanUp(source, url, indexedURL) }
        // Whatever the probe could read from the start of a file this small, the scan finds all of them.
        let scanned = try await MKVProbe.scanKeyframes(url: url, videoIndex: 0)
        let reference = try await MKVProbe.probe(url: indexedURL).keyframes
        #expect(scanned.count == reference.count, "scanned \(scanned.count), indexed \(reference.count)")
        for (a, b) in zip(scanned, reference) { #expect(abs(a.seconds - b.seconds) < 0.002) }
        // And the session plays it from a plan built on either.
        let session = try await RemuxSession.start(url: url, preferredAudioLanguage: nil)
        defer { session.stop() }
        #expect(session.segments.count >= 1)
    }

    @Test func onlyAnIndexThatReachesTheEndCounts() {
        let hour: Duration = .seconds(3600)
        #expect(MKVProbe.isCompleteIndex([.zero, .seconds(3.5), .seconds(7), .seconds(3590)], duration: hour))
        #expect(!MKVProbe.isCompleteIndex([.zero, .seconds(3.5), .seconds(7)], duration: hour))  // what probing alone leaves
        #expect(!MKVProbe.isCompleteIndex([.zero], duration: hour))
        #expect(!MKVProbe.isCompleteIndex([], duration: hour))
        #expect(MKVProbe.isCompleteIndex([.zero, .seconds(3)], duration: .zero))  // unknown duration: take what there is
        // A 3-hour film may stop its index a few minutes short; 5% of the length is tolerated.
        #expect(MKVProbe.isCompleteIndex([.zero, .seconds(10_500)], duration: .seconds(10_800)))
        #expect(!MKVProbe.isCompleteIndex([.zero, .seconds(5000)], duration: .seconds(10_800)))
    }

    @Test func readsChapters() async throws {
        let source = try await mp4(seconds: 6)
        let url = try mkv(source, .init(chapters: [("Opening", 0), ("The middle", 2.5), ("Finale", 4)]))
        defer { cleanUp(source, url) }

        let chapters = try await MKVProbe.probe(url: url).chapters
        #expect(chapters.map(\.title) == ["Opening", "The middle", "Finale"])
        #expect(chapters.map { $0.start.seconds } == [0, 2.5, 4])
        #expect(chapters.map(\.id) == [0, 1, 2])
    }

    @Test func recognizesHDR10FromTheTransferFunction() async throws {
        let source = try await mp4(flavor: .hdr10HEVC, audio: [])
        let url = try mkv(source)
        defer { cleanUp(source, url) }

        let video = try #require(try await MKVProbe.probe(url: url).video.first)
        #expect(video.codec == "hevc")
        #expect(video.hdr == .hdr10)
        #expect(video.transferFunction == "smpte2084")
        #expect(video.colorPrimaries == "bt2020")
    }

    @Test func recognizesDolbyVisionFromItsConfigurationRecord() async throws {
        let source = try await mp4(flavor: .hdr10HEVC, audio: [])
        let url = try mkv(source, .init(dolbyVision: (profile: 8, compatibilityID: 1)))
        defer { cleanUp(source, url) }

        let video = try #require(try await MKVProbe.probe(url: url).video.first)
        #expect(video.hdr == .dolbyVision(profile: 8, compatibilityID: 1))
        #expect(video.hdr.detailName == "Dolby Vision 8.1")
    }

    @Test func readsTextSubtitleTracksWithTheirFlags() async throws {
        let source = try await mp4(audio: ["eng"])
        let url = try mkv(source, .init(subtitle: (language: "ita", forced: true)))
        defer { cleanUp(source, url) }

        let subtitle = try #require(try await MKVProbe.probe(url: url).subtitles.first)
        #expect(subtitle.codec == "subrip")
        #expect(subtitle.language == "ita")
        #expect(subtitle.isForced)
        #expect(!subtitle.isDefault)
    }

    @Test func probesAnMP4TooAndLeavesItsSizeAlone() async throws {
        let source = try await mp4(audio: ["eng"])
        defer { cleanUp(source) }
        let result = try await MKVProbe.probe(url: source)
        #expect(result.formatName.contains("mp4"))
        #expect(result.video.first?.width == 320)
    }

    @Test func failsClearlyForMissingAndCorruptFiles() async throws {
        await #expect(throws: MKVProbe.Failure.self) {
            try await MKVProbe.probe(url: URL(fileURLWithPath: "/definitely/not/here.mkv"))
        }
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-junk-\(UUID().uuidString).mkv")
        try Data("this is not a matroska file at all".utf8).write(to: junk)
        defer { cleanUp(junk) }
        do {
            _ = try await MKVProbe.probe(url: junk)
            Issue.record("expected a failure")
        } catch let failure as MKVProbe.Failure {
            #expect(failure.errorDescription?.hasPrefix("This file can't be read") == true)
        }
    }
}
