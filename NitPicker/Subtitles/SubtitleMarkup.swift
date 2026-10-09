import Foundation

/// Turns cue text with inline markup into styled runs. Italic, bold and underline are kept;
/// every other tag (`<font>`, `<c.class>`, `<v Name>`, WebVTT timestamps) and ASS overrides like
/// `{\an8}` are dropped.
enum SubtitleMarkup {
    struct Run: Equatable {
        var text: String
        var italic = false
        var bold = false
        var underline = false
    }

    /// Tags are short; a `<` with no `>` this close is text. The bound also keeps a line full of `<` from taking quadratic time.
    static let longestTag = 256

    static func runs(from raw: String) -> [Run] {
        let text = raw.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        var runs: [Run] = []
        var italic = 0, bold = 0, underline = 0
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            runs.append(Run(text: decodeEntities(buffer), italic: italic > 0, bold: bold > 0, underline: underline > 0))
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].prefix(Self.longestTag).firstIndex(of: ">"),
               let tag = tagName(String(text[text.index(after: index)..<close])) {
                flushBuffer()
                let adjust = tag.closing ? -1 : 1
                switch tag.name {
                case "i": italic = max(0, italic + adjust)
                case "b": bold = max(0, bold + adjust)
                case "u": underline = max(0, underline + adjust)
                default: break
                }
                index = text.index(after: close)
            } else {
                buffer.append(character)
                index = text.index(after: index)
            }
        }
        flushBuffer()
        return runs
    }

    /// The text without any markup.
    static func plainText(from raw: String) -> String {
        runs(from: raw).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attributedString(from raw: String) -> AttributedString {
        var result = AttributedString()
        for run in runs(from: raw) {
            var piece = AttributedString(run.text)
            switch (run.italic, run.bold) {
            case (true, true): piece.inlinePresentationIntent = [.emphasized, .stronglyEmphasized]
            case (true, false): piece.inlinePresentationIntent = .emphasized
            case (false, true): piece.inlinePresentationIntent = .stronglyEmphasized
            case (false, false): break
            }
            if run.underline { piece.underlineStyle = .single }
            result += piece
        }
        return result
    }

    /// `i`, `/b`, `c.yellow`, `v Fred`, `00:01.000` all count as tags. A lone `<` (as in "a < b")
    /// doesn't: a tag name must start with a letter, a digit or `/`.
    private static func tagName(_ inner: String) -> (name: String, closing: Bool)? {
        guard let first = inner.first, first.isLetter || first.isNumber || first == "/" else { return nil }
        let closing = first == "/"
        let body = closing ? String(inner.dropFirst()) : inner
        let name = body.prefix { $0 != " " && $0 != "." && $0 != "\t" }.lowercased()
        return (name, closing)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
