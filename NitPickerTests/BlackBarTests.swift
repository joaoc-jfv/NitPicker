import CoreGraphics
import Foundation
import Testing
@testable import NitPicker

enum BarImage {
    /// A grey picture in a black frame: `bars` are the fractions of each side that stay black.
    static func make(width: Int = 640, height: Int = 360, top: Double = 0, bottom: Double = 0, left: Double = 0, right: Double = 0, level: UInt8 = 120) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let firstRow = Int(Double(height) * top), lastRow = height - 1 - Int(Double(height) * bottom)
        let firstColumn = Int(Double(width) * left), lastColumn = width - 1 - Int(Double(width) * right)
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn { pixels[row * width + column] = level &+ UInt8((row + column) % 20) }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

@Suite struct BlackBarDetectorTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func findsLetterboxBarsAndTheRatioOfWhatIsLeft() throws {
        // 2.39:1 inside 16:9 leaves bars of about 12.8% above and below.
        let bars = try #require(BlackBarDetector.bars(in: BarImage.make(top: 0.128, bottom: 0.128)))
        #expect(abs(bars.top - 0.128) < 0.02 && abs(bars.bottom - 0.128) < 0.02 && bars.left < 0.01 && bars.right < 0.01)
        let ratio = try #require(BlackBarDetector.cropRatio(bars: bars, displaySize: hd))
        #expect(abs(ratio - 2.39) < 0.15, "\(ratio)")
    }

    @Test func findsPillarboxBars() throws {
        let bars = try #require(BlackBarDetector.bars(in: BarImage.make(left: 0.125, right: 0.125)))
        let ratio = try #require(BlackBarDetector.cropRatio(bars: bars, displaySize: hd))
        #expect(abs(ratio - 4.0 / 3) < 0.08, "\(ratio)")
    }

    @Test func aPictureWithoutBarsHasNothingToCrop() throws {
        let bars = try #require(BlackBarDetector.bars(in: BarImage.make()))
        #expect(BlackBarDetector.cropRatio(bars: bars, displaySize: hd) == nil)
        #expect(BlackBarDetector.cropRatio(bars: BlackBarDetector.Bars(top: 0.01, bottom: 0.01), displaySize: hd) == nil, "a sliver isn't worth it")
    }

    @Test func aBlackFrameSaysNothing() {
        #expect(BlackBarDetector.bars(in: BarImage.make(top: 0.49, bottom: 0.49, left: 0.49, right: 0.49)) == nil)
        #expect(BlackBarDetector.bars(luma: [UInt8](repeating: 0, count: 64 * 64), width: 64, height: 64) == nil)
    }

    @Test func aStrayBrightPixelInABarDoesNotCountAsPicture() throws {
        var luma = [UInt8](repeating: 0, count: 100 * 100)
        for row in 20..<80 { for column in 0..<100 { luma[row * 100 + column] = 120 } }
        luma[5 * 100 + 50] = 255
        let bars = try #require(BlackBarDetector.bars(luma: luma, width: 100, height: 100))
        #expect(abs(bars.top - 0.2) < 0.001 && abs(bars.bottom - 0.2) < 0.001)
    }

    @Test func stillsAgreeOnTheSmallestBarSoDarkScenesOnlyMakeItCautious() throws {
        let wide = BlackBarDetector.Bars(top: 0.128, bottom: 0.128)
        let darkScene = BlackBarDetector.Bars(top: 0.30, bottom: 0.30, left: 0.2, right: 0.2)
        let common = try #require(BlackBarDetector.commonBars([wide, wide, darkScene, wide, nil, wide]))
        #expect(common == wide)
        #expect(BlackBarDetector.commonBars([wide, wide, nil, nil, wide]) == nil, "too few usable stills")
    }

    @Test func onlyTheThinnerBarOfAPairIsCroppedBecauseTheCropIsCentred() throws {
        let uneven = BlackBarDetector.Bars(top: 0.20, bottom: 0.10)
        let ratio = try #require(BlackBarDetector.cropRatio(bars: uneven, displaySize: hd))
        #expect(abs(ratio - (1920.0 / 1080) / 0.8) < 0.001)
    }
}

@MainActor
@Suite struct BlackBarPlaybackTests {
    private func player(image: CGImage?, preferences: Preferences = TestPreferences.make()) -> (PlayerModel, FakeEngine) {
        let engine = FakeEngine()
        engine.thumbnailImage = image
        engine.info.resolution = CGSize(width: 1920, height: 1080)
        engine.info.displaySize = CGSize(width: 1920, height: 1080)
        let model = PlayerModel(services: .testing(preferences: preferences), engineFactory: { _ in engine })
        return (model, engine)
    }

    @Test func detectingCropsTheBarsAndAPresetReplacesIt() async {
        let (model, engine) = player(image: BarImage.make(top: 0.128, bottom: 0.128))
        defer { model.close() }
        model.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { model.state == .playing && model.duration > .zero }

        await waitUntil("the artwork request") { engine.thumbnailRequests.count == 1 }
        model.detectBlackBars()
        await waitUntil("a detected crop") { model.videoLayout.detectedCrop != nil }
        #expect(abs((model.videoLayout.detectedCrop ?? 0) - 2.39) < 0.15)
        #expect(engine.thumbnailRequests.count == 11, "the artwork and ten samples")
        #expect(model.toast?.text.hasPrefix("Cropped black bars: 2.") == true)
        #expect(!model.videoLayout.isDefault)

        model.setCrop(.r185)
        #expect(model.videoLayout.detectedCrop == nil && model.videoLayout.crop == .r185)
    }

    @Test func aPictureWithoutBarsSaysSoAndChangesNothing() async {
        let (model, _) = player(image: BarImage.make())
        defer { model.close() }
        model.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { model.state == .playing && model.duration > .zero }
        model.detectBlackBars()
        await waitUntil("the answer") { model.toast?.text == "No black bars found" }
        #expect(model.videoLayout.isDefault)
    }

    @Test func anEngineWithoutStillsFindsNothing() async {
        let (model, _) = player(image: nil)
        defer { model.close() }
        model.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { model.state == .playing && model.duration > .zero }
        model.detectBlackBars()
        await waitUntil("the answer") { model.toast?.text == "No black bars found" }
        #expect(model.videoLayout.isDefault)
    }

    @Test func theAutomaticSettingCropsAtOpenWithoutAnnouncingAMiss() async {
        let preferences = TestPreferences.make()
        let (model, _) = player(image: BarImage.make(left: 0.125, right: 0.125), preferences: preferences)
        defer { model.close() }
        model.setCropsBlackBarsAutomatically(true)
        #expect(preferences.cropsBlackBarsAutomatically)
        model.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("the automatic crop", timeout: .seconds(8)) { model.videoLayout.detectedCrop != nil }
        #expect(abs((model.videoLayout.detectedCrop ?? 0) - 4.0 / 3) < 0.1)
    }

    @Test func anOffSettingLeavesTheFileAlone() async throws {
        let (model, engine) = player(image: BarImage.make(top: 0.128, bottom: 0.128))
        defer { model.close() }
        model.open(URL(fileURLWithPath: "/Movies/film.mp4"))
        await waitUntil("playback") { model.state == .playing }
        try await Task.sleep(for: .seconds(2))
        #expect(model.videoLayout.isDefault && engine.thumbnailRequests.count <= 1, "only the artwork")
    }

    @Test func aDetectedCropIsAppliedByTheGeometry() {
        var layout = VideoLayout()
        layout.detectedCrop = 2.0
        let placement = VideoGeometry.placement(container: CGSize(width: 1600, height: 900), videoSize: CGSize(width: 1920, height: 1080), layout: layout)
        #expect(abs(placement.clipRect.width - 1600) < 0.5 && abs(placement.clipRect.height - 800) < 0.5 && abs(placement.clipRect.minY - 50) < 0.5)
        #expect(VideoLayout.label(forRatio: 2.3529) == "2.35:1")
    }

    @Test func aRunOvertakenByTheNextFileLeavesTheNextFilesRunGoing() async {
        final class Engines { var all: [FakeEngine] = [] }
        let engines = Engines(), image = BarImage.make(top: 0.128, bottom: 0.128)
        let model = PlayerModel(services: .testing(), engineFactory: { _ in
            let engine = FakeEngine()
            engine.thumbnailImage = image
            engine.thumbnailDelay = .milliseconds(600)
            engines.all.append(engine)
            return engine
        })
        defer { model.close() }
        model.open(URL(fileURLWithPath: "/Movies/one.mp4"))
        await waitUntil("the first file") { model.state == .playing && model.duration > .zero }
        model.detectBlackBars()
        #expect(model.isDetectingBlackBars)

        model.open(URL(fileURLWithPath: "/Movies/two.mp4"))  // the first run is cancelled but its still is still decoding
        await waitUntil("the second file") { engines.all.count == 2 && model.state == .playing && model.duration > .zero }
        model.detectBlackBars()
        try? await Task.sleep(for: .milliseconds(900))  // the first run has woken up and ended by now
        #expect(model.isDetectingBlackBars, "the second file's run is still looking")
    }
}

@MainActor
@Suite struct BlackBarRealFileTests {
    @Test func findsTheBarsInARealLetterboxedFileWithTheAVFoundationEngine() async throws {
        // 640×360 with 12.8% bars: a 2.39:1 picture inside 16:9.
        let url = try await TestVideo.make(seconds: 20, size: CGSize(width: 640, height: 360), letterbox: 0.128)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PlayerModel(services: .testing())
        defer { model.close() }
        model.open(url)
        await waitUntil("playback", timeout: .seconds(10)) { model.state == .playing && model.duration.seconds > 10 }
        await waitUntil("media info") { model.mediaInfo?.presentationSize != nil }
        model.detectBlackBars()
        await waitUntil("the crop", timeout: .seconds(15)) { model.videoLayout.detectedCrop != nil }
        let ratio = try #require(model.videoLayout.detectedCrop)
        #expect(abs(ratio - 2.39) < 0.2, "\(ratio)")
    }

    @Test func findsNothingToCropInAFileWithoutBars() async throws {
        let url = try await TestVideo.make(seconds: 20, size: CGSize(width: 640, height: 360), letterbox: 0.0001)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PlayerModel(services: .testing())
        defer { model.close() }
        model.open(url)
        await waitUntil("playback", timeout: .seconds(10)) { model.state == .playing && model.duration.seconds > 10 }
        await waitUntil("media info") { model.mediaInfo?.presentationSize != nil }
        model.detectBlackBars()
        await waitUntil("the answer", timeout: .seconds(15)) { model.toast?.text == "No black bars found" }
        #expect(model.videoLayout.detectedCrop == nil)
    }
}
