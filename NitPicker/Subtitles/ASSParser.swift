import Foundation

/// Reads the text of an Advanced SubStation Alpha (.ass) or SubStation Alpha (.ssa) file, for the engines that don't draw ASS
/// themselves: the cues keep their words and line breaks, and lose their styling, positioning and drawings. mpv shows the
/// full styling through libass instead (PLAN.md, milestone 3.2).
enum ASSParser {
    static func parse(_ text: String) -> [SubtitleCue] {
        var fields: [String] = []
        var inEvents = false
        var cues: [SubtitleCue] = []
        for rawLine in SubtitleDecoding.normalizedLines(text) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                fields = line.dropFirst("format:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if line.lowercased().hasPrefix("dialogue:"), let cue = cue(fromDialogue: String(line.dropFirst("dialogue:".count)), fields: fields) {
                cues.append(cue)
            }
        }
        return cues
    }

    private static func cue(fromDialogue body: String, fields: [String]) -> SubtitleCue? {
        let fields = fields.isEmpty ? ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] : fields
        guard let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"),
              let textIndex = fields.firstIndex(of: "text"),
              // Only the fields before the text are split off, so a format that puts the times after it can't be read.
              startIndex < textIndex, endIndex < textIndex else { return nil }
        // The text is last and may hold commas, so only the fields before it are split off.
        let parts = body.split(separator: ",", maxSplits: textIndex, omittingEmptySubsequences: false)
        guard parts.count == textIndex + 1,
              let start = SubtitleTimestamp.parse(String(parts[startIndex])), let end = SubtitleTimestamp.parse(String(parts[endIndex])),
              end > start
        else { return nil }
        var text = String(parts[textIndex])
        // A drawing (`{\p1}...`) is a shape, not words.
        if text.range(of: #"\{[^}]*\\p[1-9]"#, options: .regularExpression) != nil { return nil }
        text = text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : SubtitleCue(start: start, end: end, text: text)
    }
}
