import Foundation

enum SubtitleLoader {
    enum LoadError: Error, Equatable {
        case unsupportedFormat
        case noCues
        case tooLarge
    }

    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]
    /// A feature film's subtitles are well under a megabyte; a file far bigger than this isn't one worth reading into memory.
    static let maximumFileSize = 20 * 1024 * 1024

    /// Reads and parses a subtitle file. Runs on whatever thread calls it, so call it off the main actor.
    static func load(from url: URL) throws -> SubtitleCueList {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumFileSize { throw LoadError.tooLarge }
        let text = SubtitleDecoding.string(from: try Data(contentsOf: url))
        let cues: [SubtitleCue]
        switch url.pathExtension.lowercased() {
        case "srt": cues = SRTParser.parse(text)
        case "vtt": cues = WebVTTParser.parse(text)
        case "ass", "ssa": cues = ASSParser.parse(text)
        default: throw LoadError.unsupportedFormat
        }
        guard !cues.isEmpty else { throw LoadError.noCues }
        return SubtitleCueList(cues)
    }
}
