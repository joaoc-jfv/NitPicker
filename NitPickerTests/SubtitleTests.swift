import Foundation
import Testing
@testable import NitPicker

private func cue(_ start: Double, _ end: Double, _ text: String = "x") -> SubtitleCue {
    SubtitleCue(start: .seconds(start), end: .seconds(end), text: text)
}

@Suite struct SubtitleTimestampTests {
    @Test func parsesCommonForms() {
        #expect(SubtitleTimestamp.parse("00:01:02,345") == .seconds(62.345))
        #expect(SubtitleTimestamp.parse("01:02:03.5") == .seconds(3723.5))
        #expect(SubtitleTimestamp.parse("01:02.250") == .seconds(62.25))
        #expect(SubtitleTimestamp.parse(" 00:00:01,000 ") == .seconds(1))
    }

    @Test func rejectsGarbage() {
        for text in [
            "", "abc", "1", "00:61:00,000", "00:00:61,000", "00:00:01,x", "00:00:01,", "-1:00:00,000", "1:2:3:4",
            "9223372036854775807:00:00,000", "100000:00:00,000",
        ] {
            #expect(SubtitleTimestamp.parse(text) == nil, "\(text)")
        }
    }

    @Test func parsesRangesWithSettingsAndRejectsBackwardsOnes() {
        let range = SubtitleTimestamp.parseRange("00:00:01,000 --> 00:00:03,500 X1:100 Y1:200")
        #expect(range?.start == .seconds(1))
        #expect(range?.end == .seconds(3.5))
        #expect(SubtitleTimestamp.parseRange("00:00:05,000 --> 00:00:03,000") == nil)
        #expect(SubtitleTimestamp.parseRange("no arrow here") == nil)
    }
}

@Suite struct SRTParserTests {
    @Test func parsesBasicCues() {
        let text = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello there.

        2
        00:00:04,000 --> 00:00:06,000
        Two lines
        of text
        """
        let cues = SRTParser.parse(text)
        #expect(cues == [cue(1, 3.5, "Hello there."), cue(4, 6, "Two lines\nof text")])
    }

    @Test func handlesCRLFAndCRLineEndings() {
        let crlf = "1\r\n00:00:01,000 --> 00:00:02,000\r\nA\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\nB\r\n"
        #expect(SRTParser.parse(crlf).map(\.text) == ["A", "B"])
        let cr = "1\r00:00:01,000 --> 00:00:02,000\rA\r\r2\r00:00:03,000 --> 00:00:04,000\rB\r"
        #expect(SRTParser.parse(cr).map(\.text) == ["A", "B"])
    }

    @Test func toleratesABOMAndMissingIndexes() {
        let text = "\u{FEFF}00:00:01,000 --> 00:00:02,000\nNo index\n"
        #expect(SRTParser.parse(text) == [cue(1, 2, "No index")])
    }

    @Test func toleratesMissingBlankLinesBetweenCues() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nFirst\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n"
        #expect(SRTParser.parse(text).map(\.text) == ["First", "Second"])
    }

    @Test func keepsNumbersThatAreCueText() {
        let text = "1\n00:00:01,000 --> 00:00:02,000\n42\n\n2\n00:00:03,000 --> 00:00:04,000\nNext\n"
        #expect(SRTParser.parse(text).map(\.text) == ["42", "Next"])
    }

    @Test func skipsMalformedBlocks() {
        let text = """
        1
        garbage --> 00:00:02,000
        Bad times

        2
        00:00:03,000 --> 00:00:04,000

        3
        00:00:05,000 --> 00:00:06,000
        Good
        """
        #expect(SRTParser.parse(text) == [cue(5, 6, "Good")])
    }

    @Test func returnsNothingForNonSubtitleText() {
        #expect(SRTParser.parse("").isEmpty)
        #expect(SRTParser.parse("just some words\nand more").isEmpty)
    }
}

@Suite struct WebVTTParserTests {
    @Test func parsesCuesWithAndWithoutIdentifiers() {
        let text = """
        WEBVTT

        intro
        00:01.000 --> 00:03.000
        First

        01:00:00.000 --> 01:00:02.500 align:start position:10%
        Second line one
        Second line two
        """
        #expect(WebVTTParser.parse(text) == [cue(1, 3, "First"), cue(3600, 3602.5, "Second line one\nSecond line two")])
    }

    @Test func skipsNoteStyleAndRegionBlocks() {
        let text = """
        WEBVTT - with a title

        NOTE this is a comment
        00:00.000 --> 00:01.000
        not a cue

        STYLE
        ::cue { color: red }

        REGION
        id:r1

        00:02.000 --> 00:03.000
        Real
        """
        #expect(WebVTTParser.parse(text) == [cue(2, 3, "Real")])
    }

    @Test func handlesCRLFAndBOM() {
        let text = "\u{FEFF}WEBVTT\r\n\r\n00:00.500 --> 00:01.500\r\nHi\r\n"
        #expect(WebVTTParser.parse(text) == [cue(0.5, 1.5, "Hi")])
    }
}

@Suite struct SubtitleDecodingTests {
    @Test func decodesUTF8WithAndWithoutBOM() {
        let text = "Olá — “quotes”"
        #expect(SubtitleDecoding.string(from: Data(text.utf8)) == text)
        #expect(SubtitleDecoding.string(from: Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
    }

    @Test func decodesUTF16WithBOM() throws {
        let text = "Привет"
        let le = Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian)))
        let be = Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
        #expect(SubtitleDecoding.string(from: le) == text)
        #expect(SubtitleDecoding.string(from: be) == text)
    }

    @Test func fallsBackToWindows1252ForLatin1Files() throws {
        let text = "Café déjà vu – “ok”"
        let data = try #require(text.data(using: .windowsCP1252))
        #expect(String(data: data, encoding: .utf8) == nil)
        #expect(SubtitleDecoding.string(from: data) == text)
        // A byte Windows-1252 leaves undefined still decodes (as Latin-1).
        #expect(!SubtitleDecoding.string(from: Data([0x41, 0x81, 0x42])).isEmpty)
    }
}

@Suite struct SubtitleMarkupTests {
    @Test func keepsItalicBoldAndUnderline() {
        let runs = SubtitleMarkup.runs(from: "a <i>b</i> <b>c<u>d</u></b>")
        #expect(runs.map(\.text) == ["a ", "b", " ", "c", "d"])
        #expect(runs.map(\.italic) == [false, true, false, false, false])
        #expect(runs.map(\.bold) == [false, false, false, true, true])
        #expect(runs.map(\.underline) == [false, false, false, false, true])
    }

    @Test func dropsOtherTagsAndAssOverrides() {
        #expect(SubtitleMarkup.plainText(from: "<font color=\"#ff0\">Hi</font> {\\an8}there") == "Hi there")
        #expect(SubtitleMarkup.plainText(from: "<v Fred><c.yellow>Hello</c> <00:01.000>you</v>") == "Hello you")
    }

    @Test func decodesEntitiesAndKeepsLoneAngleBrackets() {
        #expect(SubtitleMarkup.plainText(from: "Tom &amp; Jerry &lt;3") == "Tom & Jerry <3")
        #expect(SubtitleMarkup.plainText(from: "1 < 2 and 3 > 2") == "1 < 2 and 3 > 2")
    }

    @Test func survivesUnbalancedTags() {
        #expect(SubtitleMarkup.plainText(from: "</i>text<i>") == "text")
        #expect(String(SubtitleMarkup.attributedString(from: "<i>a</i>b").characters) == "ab")
    }
}

@Suite struct SubtitleCueListTests {
    private let list = SubtitleCueList([cue(10, 12, "c"), cue(1, 3, "a"), cue(2, 5, "b"), cue(20, 21, "d")])

    @Test func sortsByStart() {
        #expect(list.cues.map(\.text) == ["a", "b", "c", "d"])
    }

    @Test func findsTheCueShowingAtATime() {
        #expect(list.active(at: .seconds(0.5)).isEmpty)
        #expect(list.active(at: .seconds(1)).map(\.text) == ["a"])
        #expect(list.active(at: .seconds(2.5)).map(\.text) == ["a", "b"])
        #expect(list.active(at: .seconds(3)).map(\.text) == ["b"])
        #expect(list.active(at: .seconds(5)).isEmpty)
        #expect(list.active(at: .seconds(11.9)).map(\.text) == ["c"])
        #expect(list.active(at: .seconds(12)).isEmpty)
        #expect(list.active(at: .seconds(20.5)).map(\.text) == ["d"])
        #expect(list.active(at: .seconds(99)).isEmpty)
    }

    @Test func aLongCueStaysActiveAcrossLaterShortOnes() {
        let list = SubtitleCueList([cue(0, 100, "long"), cue(10, 11, "short")])
        #expect(list.active(at: .seconds(50)).map(\.text) == ["long"])
        #expect(list.active(at: .seconds(10.5)).map(\.text) == ["long", "short"])
    }

    @Test func emptyListIsFine() {
        #expect(SubtitleCueList([]).active(at: .seconds(1)).isEmpty)
    }
}

@Suite struct SidecarSubtitlesTests {
    private let media = URL(fileURLWithPath: "/movies/My Film (2024).mp4")

    private func names(_ files: [String]) -> [SidecarSubtitles.Candidate] {
        SidecarSubtitles.candidates(forMedia: media, in: files.map { URL(fileURLWithPath: "/movies/\($0)") })
    }

    @Test func matchesSameNameFiles() {
        #expect(names(["My Film (2024).srt", "My Film (2024).vtt"]).count == 2)
    }

    @Test func ignoresOtherFilesAndFormats() {
        #expect(names(["Other.srt", "My Film (2024) Extended.srt", "My Film (2024).txt", "My Film (2024).mp4", "My Film (2024).sup"]).isEmpty)
    }

    @Test func readsAssFilesAsTextAndLeavesTheImageFormatsToTheEngine() {
        #expect(names(["My Film (2024).en.ass", "My Film (2024).ssa"]).count == 2)
        let native = SidecarSubtitles.nativeCandidates(
            forMedia: media,
            in: ["My Film (2024).en.ass", "My Film (2024).fr.sup", "My Film (2024).idx", "My Film (2024).srt", "Other.ass"].map { URL(fileURLWithPath: "/movies/\($0)") }
        )
        #expect(native.map(\.url.lastPathComponent).sorted() == ["My Film (2024).en.ass", "My Film (2024).fr.sup", "My Film (2024).idx"])
        #expect(native.first { $0.url.pathExtension == "sup" }?.language == "fr")
    }

    @Test func matchesCaseInsensitively() {
        #expect(names(["MY FILM (2024).SRT"]).count == 1)
    }

    @Test func readsLanguageFromCodesAndNames() {
        let found = names(["My Film (2024).en.srt", "My Film (2024).fra.srt", "My Film (2024).German.srt", "My Film (2024).srt"])
        #expect(Set(found.compactMap(\.language)) == ["en", "fr", "de"])
        #expect(found.contains { $0.language == nil && $0.label == "Subtitles" })
    }

    @Test func labelsForcedAndHearingImpairedTracks() {
        let found = names(["My Film (2024).en.forced.srt", "My Film (2024).en.sdh.srt"])
        let english = Locale.current.localizedString(forLanguageCode: "en")!
        #expect(Set(found.map(\.label)) == ["\(english) · Forced", "\(english) · SDH"])
        #expect(found.allSatisfy { $0.language == "en" })
    }

    @Test func unknownSuffixesBecomeTheLabel() {
        #expect(names(["My Film (2024).commentary.srt"]).first?.label == "commentary")
    }
}

@MainActor
@Suite struct SubtitleStoreTests {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-subs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ preferences: Preferences = TestPreferences.make()) -> SubtitleTrackStore {
        SubtitleTrackStore(preferences: preferences, folderAccess: FolderAccess(defaults: UserDefaults(suiteName: "nitpicker-tests-\(UUID().uuidString)")!))
    }

    private let srt = "1\n00:00:01,000 --> 00:00:03,000\nHello\n\n2\n00:00:05,000 --> 00:00:06,000\nBye\n"

    @Test func discoversAndLoadsSidecars() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try srt.write(to: folder.appendingPathComponent("film.en.srt"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nBonjour\n".write(to: folder.appendingPathComponent("film.fr.vtt"), atomically: true, encoding: .utf8)
        try "ignored".write(to: folder.appendingPathComponent("film.txt"), atomically: true, encoding: .utf8)
        try "junk with no cues".write(to: folder.appendingPathComponent("film.de.srt"), atomically: true, encoding: .utf8)

        let store = store()
        await store.discover(for: folder.appendingPathComponent("film.mp4"))
        #expect(store.sidecarAccess == .available)
        #expect(Set(store.tracks.compactMap(\.language)) == ["en", "fr"])  // the empty one is dropped
    }

    @Test func reportsMissingFolderAccess() async {
        let store = store()
        await store.discover(for: URL(fileURLWithPath: "/definitely/not/a/folder/film.mp4"))
        #expect(store.sidecarAccess == .needsFolderAccess)
        #expect(store.tracks.isEmpty)
    }

    @Test func selectionAndActiveCuesFollowTheDelay() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("film.srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        let store = store()
        await store.discover(for: folder.appendingPathComponent("film.mp4"))

        #expect(store.activeCues(atPlaybackTime: .seconds(2)).isEmpty)  // nothing selected
        store.select(store.tracks[0].id)
        #expect(store.activeCues(atPlaybackTime: .seconds(2)).map(\.text) == ["Hello"])

        store.adjustDelay(by: .milliseconds(1500))  // subtitles appear 1.5 s later
        #expect(store.activeCues(atPlaybackTime: .seconds(2)).isEmpty)
        #expect(store.activeCues(atPlaybackTime: .seconds(3)).map(\.text) == ["Hello"])
        #expect(store.delayLabel == "+1.5 s")

        store.adjustDelay(by: .milliseconds(-3000))  // and now 1.5 s earlier
        #expect(store.activeCues(atPlaybackTime: .seconds(0.5)).map(\.text) == ["Hello"])
        #expect(store.delayLabel == "−1.5 s")
        store.resetDelay()
        #expect(store.delayLabel == "0.0 s")
    }

    @Test func repeatedNudgesDoNotDrift() {
        let store = store()
        for _ in 0..<30 { store.adjustDelay(by: SubtitleTrackStore.delayStep) }
        #expect(store.delay == .seconds(3))
        #expect(store.delayLabel == "+3.0 s")
    }

    @Test func addsAPickedFileOnce() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("anything.srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        let store = store()
        let first = try await store.add(fileAt: file)
        let again = try await store.add(fileAt: file)
        #expect(first == again)
        #expect(store.tracks.count == 1)
        #expect(first.label == "anything")
    }

    @Test func rejectsFilesWithoutCues() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("empty.srt")
        try "nothing".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: SubtitleLoader.LoadError.noCues) { try await store().add(fileAt: file) }
    }

    @Test func resetForgetsTheFileButKeepsTheStyle() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        let store = store()
        try await store.add(fileAt: file)
        store.select(store.tracks[0].id)
        store.adjustDelay(by: .seconds(1))
        var style = SubtitleStyle()
        style.size = .extraLarge
        store.setStyle(style)
        store.reset()
        #expect(store.tracks.isEmpty && store.selected == nil && store.delay == .zero)
        #expect(store.style.size == .extraLarge)
    }

    @Test func styleIsRemembered() {
        let preferences = TestPreferences.make()
        var style = SubtitleStyle(size: .large, background: .box, verticalOffset: 0.1)
        store(preferences).setStyle(style)
        style.verticalOffset = 0.1
        #expect(preferences.subtitleStyle == style)
        #expect(store(preferences).style == style)
    }
}

@Suite struct SubtitleStyleAndLayoutTests {
    @Test func fontSizeScalesWithVideoHeight() {
        var style = SubtitleStyle()
        #expect(style.fontSize(forVideoHeight: 1000) == 45)
        style.size = .extraLarge
        #expect(style.fontSize(forVideoHeight: 1000) == 72)
        #expect(style.fontSize(forVideoHeight: 10) == 12)  // never unreadably small
    }

    @Test func subtitlesLiftWhileControlsShow() {
        let container = CGSize(width: 1000, height: 600)
        let rect = CGRect(origin: .zero, size: container)
        let style = SubtitleStyle()
        let hidden = SubtitleLayout.bottomInset(videoRect: rect, container: container, style: style, controlsVisible: false)
        let shown = SubtitleLayout.bottomInset(videoRect: rect, container: container, style: style, controlsVisible: true)
        #expect(hidden == 36)
        #expect(shown == 100)
        // Black bars under the video already provide most of the clearance.
        let letterboxed = CGRect(x: 0, y: 50, width: 1000, height: 500)
        #expect(SubtitleLayout.bottomInset(videoRect: letterboxed, container: container, style: style, controlsVisible: true) == 50)
    }
}

@MainActor
@Suite struct FolderAccessTests {
    @Test func remembersAFolderAndCoversItsFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: "nitpicker-tests-\(UUID().uuidString)")!
        let access = FolderAccess(defaults: defaults)

        #expect(access.beginAccess(toFolderContaining: folder.appendingPathComponent("a.mp4")) == nil)
        try access.remember(folder)
        let scoped = access.beginAccess(toFolderContaining: folder.appendingPathComponent("sub/b.mp4"))
        #expect(scoped?.standardizedFileURL.path == folder.standardizedFileURL.path)
        scoped?.stopAccessingSecurityScopedResource()
        // A sibling folder with a similar name is not covered.
        #expect(access.beginAccess(toFolderContaining: URL(fileURLWithPath: folder.path + "-other/c.mp4")) == nil)
    }
}


@Suite struct ASSParserTests {
    private let file = """
    [Script Info]
    Title: Test

    [V4+ Styles]
    Format: Name, Fontname
    Style: Default,Arial

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,{\\an8\\i1}Hello, world{\\i0}\\Nsecond line
    Dialogue: 0,0:01:00.00,0:01:02.25,Default,Bob,0,0,0,,Bye\\hnow
    Dialogue: 0,0:00:10.00,0:00:11.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}
    Dialogue: 0,0:00:20.00,0:00:19.00,Default,,0,0,0,,backwards
    Comment: 0,0:00:30.00,0:00:31.00,Default,,0,0,0,,not a cue
    """

    @Test func readsTextTimingAndLineBreaks() {
        let cues = ASSParser.parse(file)
        #expect(cues.count == 2)
        #expect(cues[0].start == .seconds(1.5) && cues[0].end == .seconds(3))
        // Commas inside the text stay, the override tags are left for SubtitleMarkup to drop, `\N` is a line break.
        #expect(SubtitleMarkup.plainText(from: cues[0].text) == "Hello, world\nsecond line")
        #expect(cues[1].start == .seconds(60) && cues[1].end == .seconds(62.25))
        #expect(cues[1].text == "Bye now")
    }

    @Test func honoursACustomFormatLine() {
        let custom = "[Events]\nFormat: Marked, Start, End, Text\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Hi there"
        #expect(ASSParser.parse(custom).map(\.text) == ["Hi there"])
    }

    @Test func skipsAFormatWithTheTimesAfterTheText() {
        let crafted = "[Events]\nFormat: Text, Start, End\nDialogue: hello,0:00:01.00,0:00:02.00"
        #expect(ASSParser.parse(crafted).isEmpty)
    }

    @Test func loadsThroughTheLoaderAndIgnoresOtherSections() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-\(UUID().uuidString).ass")
        defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url, atomically: true, encoding: .utf8)
        #expect(try SubtitleLoader.load(from: url).cues.count == 2)
        #expect(ASSParser.parse("[Script Info]\nTitle: nothing").isEmpty)
    }
}
