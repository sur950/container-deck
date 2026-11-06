import SwiftUI

/// Turns a model's answer into blocks the chat can draw: paragraphs, headings, lists,
/// fenced code, quotes, tables and rules. Small and forgiving, because answers stream in
/// half finished (an open code fence shows as code right away).
enum ChatMarkdown {
    struct ListItem: Equatable {
        /// "•" for bullets, "1." for numbered items.
        var marker: String
        var text: String
        var indent: Int
    }

    enum Block: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case list([ListItem])
        case code(language: String, code: String)
        case quote(String)
        /// First row is the header.
        case table([[String]])
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var list: [ListItem] = []
        var quote: [String] = []
        var table: [String] = []
        var code: (language: String, fence: String, lines: [String])?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushList() {
            if !list.isEmpty { blocks.append(.list(list)) }
            list = []
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            quote = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            if table.count >= 2, isSeparatorRow(table[1]) {
                let rows = table.enumerated().filter { $0.offset != 1 }.map { cells($0.element) }
                blocks.append(.table(rows))
            } else {
                blocks.append(.paragraph(table.joined(separator: "\n")))
            }
            table = []
        }
        func flushAll() {
            flushParagraph()
            flushList()
            flushQuote()
            flushTable()
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if isClosingFence(trimmed, fence: open.fence) {
                    blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }
            if let fence = openingFence(trimmed) {
                flushAll()
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                code = (language, fence, [])
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                blocks.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                flushList()
                flushQuote()
                table.append(trimmed)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                flushTable()
                quote.append(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                flushTable()
                list.append(item)
                continue
            }
            if !list.isEmpty, line.first == " " || line.first == "\t" {
                // Wrapped line of the last list item.
                list[list.count - 1].text += " " + trimmed
                continue
            }
            flushList()
            flushQuote()
            flushTable()
            paragraph.append(trimmed)
        }
        if let open = code {
            // Still streaming: show what came so far as code.
            blocks.append(.code(language: open.language, code: open.lines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    /// Thinking that some models put inline as `<think>...</think>` before the answer.
    /// `isThinking` is true while the closing tag has not come yet.
    static func splitThinking(_ text: String) -> (thinking: String, answer: String, isThinking: Bool) {
        let start = text.drop { $0.isWhitespace }
        guard start.hasPrefix("<think>") else { return ("", text, false) }
        let body = start.dropFirst("<think>".count)
        guard let end = body.range(of: "</think>") else {
            return (body.trimmingCharacters(in: .whitespacesAndNewlines), "", true)
        }
        let thinking = body[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = body[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking, answer, false)
    }

    /// Bold, italic, links and inline code. Falls back to the plain text.
    static func inline(_ text: String, codeBackground: Color? = nil) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(size: 12.5, design: .monospaced)
            if let codeBackground { result[run.range].backgroundColor = codeBackground }
        }
        return result
    }

    // MARK: Pieces

    private static func openingFence(_ trimmed: String) -> String? {
        for mark in ["`", "~"] where trimmed.hasPrefix(String(repeating: mark, count: 3)) {
            return String(trimmed.prefix { String($0) == mark })
        }
        return nil
    }

    private static func isClosingFence(_ trimmed: String, fence: String) -> Bool {
        guard let mark = fence.first, trimmed.hasPrefix(fence) else { return false }
        return trimmed.allSatisfy { $0 == mark }
    }

    private static func heading(_ trimmed: String) -> Block? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> ListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let width = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let rest = line.dropFirst(leading.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return ListItem(marker: "•", text: text, indent: min(width / 2, 3))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let dot = afterDigits.first, dot == "." || dot == ")", afterDigits.dropFirst().first == " " else { return nil }
        let text = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return ListItem(marker: "\(digits).", text: text, indent: min(width / 2, 3))
    }

    private static func cells(_ row: String) -> [String] {
        var inner = Substring(row)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ row: String) -> Bool {
        let parts = cells(row)
        return !parts.isEmpty && parts.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }
}

/// What Return does in the chat composer.
enum ChatComposerKey {
    enum Action: Equatable {
        case send
        case newline
        /// Let the text field handle it (for example to confirm an input method).
        case passThrough
    }

    /// Return sends. Shift or Option with Return adds a new line.
    static func action(shift: Bool, option: Bool, composing: Bool) -> Action {
        if composing { return .passThrough }
        if shift || option { return .newline }
        return .send
    }
}
