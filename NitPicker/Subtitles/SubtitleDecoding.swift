import Foundation

enum SubtitleDecoding {
    /// Decodes subtitle file data: a byte-order mark wins, then strict UTF-8, then Windows-1252
    /// (which covers the Latin-1 files that are common for older SRTs).
    static func string(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Windows-1252 leaves a few bytes undefined; Latin-1 maps every byte.
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// LF-only text without a leading BOM character.
    static func normalizedLines(_ text: String) -> [String] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

enum SubtitleTimestamp {
    /// `hh:mm:ss,mmm`, `hh:mm:ss.mmm` or `mm:ss.mmm`. Fraction digits are a decimal fraction of a second.
    static func parse(_ text: String) -> Duration? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsParts = parts[parts.count - 1].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
        guard secondsParts.count <= 2, let wholeSeconds = Int(secondsParts[0]),
              let minutes = Int(parts[parts.count - 2]),
              let hours = parts.count == 3 ? Int(parts[0]) : 0,
              // The hours bound keeps `hours * 3600` from overflowing on a crafted file.
              minutes < 60, wholeSeconds < 60, hours >= 0, hours < 100_000, minutes >= 0, wholeSeconds >= 0
        else { return nil }
        var fraction = 0.0
        if secondsParts.count == 2 {
            guard !secondsParts[1].isEmpty, secondsParts[1].allSatisfy({ ("0"..."9").contains($0) }),
                  let value = Double("0." + secondsParts[1]) else { return nil }
            fraction = value
        }
        return .seconds(Double(hours * 3600 + minutes * 60 + wholeSeconds) + fraction)
    }

    /// Splits `start --> end [settings]` into its two times.
    static func parseRange(_ line: String) -> (start: Duration, end: Duration)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let startText = String(line[..<arrow.lowerBound])
        let endText = line[arrow.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = parse(startText), let end = parse(endText), end > start else { return nil }
        return (start, end)
    }
}
