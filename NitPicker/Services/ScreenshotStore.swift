import Foundation

/// Where screenshots go: the Pictures folder, in a "Nit Picker" folder of its own, without asking each time. The sandbox allows it
/// through the Pictures entitlement.
@MainActor
final class ScreenshotStore {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.picturesFolder().appendingPathComponent("Nit Picker", isDirectory: true)
    }

    /// The real Pictures folder. `FileManager` answers with the sandbox container's copy, which nobody looks in.
    nonisolated static func picturesFolder() -> URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Pictures", isDirectory: true)
        }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
    }

    var folder: URL { directory }

    /// Writes the screenshot as `<title> <time>.<ext>`, adding a number if the name is taken. Returns the file.
    func save(_ output: ScreenshotEncoder.Output, title: String, at time: Duration) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "\(Self.safeName(title)) \(Self.timeStamp(time))"
        var number = 1
        while true {
            let name = number == 1 ? base : "\(base) \(number)"
            let target = directory.appendingPathComponent(name).appendingPathExtension(output.fileExtension)
            do {
                // Refuses to replace a file, so two screenshots of one moment can't overwrite each other.
                try output.data.write(to: target, options: .withoutOverwriting)
                return target
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }

    /// `1-02-03` for an hour, two minutes and three seconds in; `12-34` under an hour.
    nonisolated static func timeStamp(_ time: Duration) -> String {
        let total = max(0, Int(time.seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, seconds = total % 60
        return hours > 0 ? String(format: "%d-%02d-%02d", hours, minutes, seconds) : String(format: "%d-%02d", minutes, seconds)
    }

    /// A file name may be 255 bytes; this leaves room for the time, a number and the extension.
    nonisolated static let maximumNameBytes = 200

    /// A title made safe for a file name, and short.
    nonisolated static func safeName(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n\r\t")).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".")))
        var short = cleaned.count > 80 ? String(cleaned.prefix(80)) : cleaned
        // Eighty characters can be far more bytes (emoji, scripts outside Latin); drop whole characters until it fits.
        while short.utf8.count > maximumNameBytes { short.removeLast() }
        short = short.trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "Screenshot" : short
    }
}
