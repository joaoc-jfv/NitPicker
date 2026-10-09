import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import NitPicker

@Suite struct ScreenshotNamingTests {
    @Test func namesFilesByTitleAndTime() {
        #expect(ScreenshotStore.timeStamp(.seconds(754)) == "12-34")
        #expect(ScreenshotStore.timeStamp(.seconds(3723)) == "1-02-03")
        #expect(ScreenshotStore.timeStamp(.seconds(-4)) == "0-00")
        #expect(ScreenshotStore.safeName("A/B: C\\D") == "A B C D")
        #expect(ScreenshotStore.safeName("  .. ") == "Screenshot")
        #expect(ScreenshotStore.safeName(String(repeating: "x", count: 200)).count == 80)
        // Eighty family emoji are far more than a file name's 255 bytes.
        let family = ScreenshotStore.safeName(String(repeating: "👨‍👩‍👧‍👦", count: 80))
        #expect(family.utf8.count <= ScreenshotStore.maximumNameBytes && !family.isEmpty)
    }

    @MainActor
    @Test func neverOverwritesAnEarlierScreenshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScreenshotStore(directory: directory)
        let output = ScreenshotEncoder.Output(data: Data([1, 2, 3]), fileExtension: "png", isHDR: false)
        let first = try store.save(output, title: "Film", at: .seconds(65))
        let second = try store.save(output, title: "Film", at: .seconds(65))
        #expect(first.lastPathComponent == "Film 1-05.png" && second.lastPathComponent == "Film 1-05 2.png")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        let long = try store.save(output, title: String(repeating: "👨‍👩‍👧‍👦", count: 80), at: .seconds(65))
        #expect(FileManager.default.fileExists(atPath: long.path))
    }

    @MainActor
    @Test func theRealPicturesFolderIsNotTheContainersCopy() {
        let pictures = ScreenshotStore.picturesFolder().path
        #expect(pictures.hasSuffix("/Pictures") && !pictures.contains("/Library/Containers/"))
    }
}

@MainActor
@Suite struct ScreenshotCaptureTests {
    private func image(of data: Data) throws -> (CGImage, [CFString: Any]) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (image, properties)
    }

    @Test func anSDRFrameBecomesAPNGOfTheRightSize() async throws {
        let url = try await TestVideo.make(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AVFoundationEngine()
        try await engine.load(url, startAt: .seconds(1))
        defer { engine.close() }
        engine.pause()
        let frame = try #require(await engine.captureFrame())
        guard case .sdr(let picture) = frame else { Issue.record("expected an SDR frame"); return }
        #expect(picture.width == 320 && picture.height == 240)
        let output = try #require(ScreenshotEncoder.encode(frame))
        #expect(output.fileExtension == "png" && !output.isHDR)
        let (decoded, _) = try image(of: output.data)
        #expect(decoded.width == 320 && decoded.height == 240)
    }

    @Test func anHDRFrameKeepsItsHDRColourInA10BitHEIC() async throws {
        let url = try await TestVideo.make(seconds: 3, flavor: .hdr10HEVC)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AVFoundationEngine()
        try await engine.load(url, startAt: .seconds(1))
        defer { engine.close() }
        engine.pause()
        let frame = try #require(await engine.captureFrame())
        guard case .hdr(_, let transfer) = frame else { Issue.record("expected an HDR frame, got \(frame)"); return }
        #expect(transfer == .pq)
        let output = try #require(ScreenshotEncoder.encode(frame))
        #expect(output.fileExtension == "heic" && output.isHDR)
        let (decoded, properties) = try image(of: output.data)
        #expect(decoded.width == 320 && decoded.height == 240)
        let space = decoded.colorSpace?.name as String? ?? ""
        #expect(space.contains("2100") && space.contains("PQ"), "colour space \(space)")
        #expect(decoded.bitsPerComponent > 8 || (properties[kCGImagePropertyDepth] as? Int ?? 0) >= 10, "depth \(properties[kCGImagePropertyDepth] ?? "nil")")
    }

    @Test func mpvGivesTheFrameOnScreen() async throws {
        let file = try LegacyFixture.makeMPEG4(seconds: 4)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = MPVEngine()
        try await engine.load(file, startAt: nil)
        defer { engine.close() }
        await engine.seek(to: .seconds(2), precise: true)
        try await Task.sleep(for: .milliseconds(300))
        let frame = try #require(await engine.captureFrame())
        guard case .sdr(let picture) = frame else { Issue.record("expected an SDR frame"); return }
        #expect(picture.width == 320 && picture.height == 240)
        let output = try #require(ScreenshotEncoder.encode(frame))
        let (decoded, _) = try image(of: output.data)
        // The clip is a gradient, so the pixels are not all alike.
        let data = try #require(decoded.dataProvider?.data as Data?)
        #expect(Set(stride(from: 0, to: data.count, by: 211).map { data[$0] }).count > 10)
    }

    @Test func theModelSavesWhatTheEngineGivesAndAnnouncesIt() async throws {
        let engine = FakeEngine()
        let size = 4
        let provider = try #require(CGDataProvider(data: Data(repeating: 200, count: size * size) as CFData))
        let picture = try #require(CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        engine.capturedFrame = .sdr(picture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nitpicker-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let player = PlayerModel(services: .testing(screenshots: ScreenshotStore(directory: directory)), engineFactory: { _ in engine })
        defer { player.close() }
        player.open(URL(fileURLWithPath: "/Movies/My Film.mp4"))
        await waitUntil("playback") { player.state == .playing }
        engine.advance(to: .seconds(61))
        await waitUntil("time") { player.currentTime == .seconds(61) }

        player.takeScreenshot()
        await waitUntil("the file") { player.lastScreenshot != nil }
        let saved = try #require(player.lastScreenshot)
        #expect(saved.lastPathComponent == "My Film 1-01.png" && saved.deletingLastPathComponent().path == directory.path)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(player.toast?.text == "Screenshot saved to Pictures")

        engine.capturedFrame = nil
        player.takeScreenshot()
        await waitUntil("the failure") { player.toast?.text == "Couldn't take a screenshot" }
    }
}
