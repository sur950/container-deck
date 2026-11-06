import Foundation

/// One progress line from `container image pull` (1.6 prints plain lines when piped):
///
///     [1/2] Fetching image [0s]
///     [1/2] Fetching image (4 of 18 blobs) [4s]
///     [1/2] Fetching image 12% (20 of 52 blobs, 2.1/16.7 MB, 2 KB/s) [9s]
///     [2/2] Unpacking image for platform linux/arm64 0% [26s]
///     [2/2] Unpacking image for platform linux/s390x 100% (448 entries, 4.0 MB) [27s]
public struct PullProgress: Sendable, Hashable {
    public var step: Int
    public var totalSteps: Int
    /// "Fetching image" or "Unpacking image for platform linux/arm64".
    public var title: String
    /// 0 to 100 for the current step, when the tool prints one.
    public var percent: Double?
    /// Text in brackets, like "20 of 52 blobs, 2.1/16.7 MB, 2 KB/s".
    public var detail: String?
    public var elapsedSeconds: Int?

    public init(step: Int, totalSteps: Int, title: String, percent: Double? = nil, detail: String? = nil, elapsedSeconds: Int? = nil) {
        self.step = step
        self.totalSteps = totalSteps
        self.title = title
        self.percent = percent
        self.detail = detail
        self.elapsedSeconds = elapsedSeconds
    }

    /// 0...1 over all steps. nil when the current step has no percent yet.
    public var fraction: Double? {
        guard let percent, totalSteps > 0 else { return nil }
        let done = Double(max(step - 1, 0)) + min(max(percent, 0), 100) / 100
        return min(done / Double(totalSteps), 1)
    }

    /// Parses one line. nil for anything that is not a progress line.
    public static func parse(_ line: String) -> PullProgress? {
        var text = CLIText.strippingANSI(line).trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else { return nil }
        let counter = text[text.index(after: text.startIndex)..<close].split(separator: "/")
        guard counter.count == 2, let step = Int(counter[0]), let total = Int(counter[1]), total > 0 else { return nil }
        text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)

        var elapsed: Int?
        if text.hasSuffix("s]"), let open = text.lastIndex(of: "[") {
            let inner = text[text.index(after: open)..<text.index(text.endIndex, offsetBy: -2)]
            if let seconds = Int(inner) {
                elapsed = seconds
                text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        var detail: String?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            detail = CLIText.nonEmpty(String(text[text.index(after: open)..<text.index(before: text.endIndex)]))
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }

        var percent: Double?
        if text.hasSuffix("%") {
            let words = text.split(separator: " ")
            if let last = words.last, let value = Double(last.dropLast()) {
                percent = value
                text = words.dropLast().joined(separator: " ")
            }
        }

        guard !text.isEmpty else { return nil }
        return PullProgress(step: step, totalSteps: total, title: text, percent: percent, detail: detail, elapsedSeconds: elapsed)
    }

    /// True when `next` updates the same step as `previous` (so a log can replace the line).
    public static func isSameStep(_ previous: String, _ next: String) -> Bool {
        guard let a = parse(previous), let b = parse(next) else { return false }
        return a.step == b.step && a.totalSteps == b.totalSteps && a.title == b.title
    }
}

public enum ImagePlatform {
    /// "linux/arm64" on Apple silicon. `image pull` without `--platform` fetches every platform.
    public static var host: String {
        "linux/" + hostArchitecture
    }

    /// "arm64" on Apple silicon, "amd64" on Intel.
    public static var hostArchitecture: String {
        ContainerClient.hostArchitecture
    }
}

public enum CLIFailure {
    /// The last "Error: ..." line of streamed output, without the prefix.
    /// Usage errors print help text after the error, so the last line is not enough.
    public static func message(in lines: [String]) -> String? {
        for line in lines.reversed() {
            let clean = CLIText.strippingANSI(line).trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix("Error:") {
                return CLIText.nonEmpty(String(clean.dropFirst("Error:".count)))
            }
        }
        return nil
    }
}
