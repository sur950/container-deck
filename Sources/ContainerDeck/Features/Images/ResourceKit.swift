import SwiftUI
import AppKit
import DeckCore

// Small helpers shared by the Images (with Explore), Volumes and Networks screens.
// Names use a "Resource" or "ImageRef" prefix so they do not clash with other screens.

/// Compares image references written in short or full form.
enum ImageRefMatch {
    /// "nginx" becomes "docker.io/library/nginx:latest".
    static func normalize(_ raw: String) -> String {
        var ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return "" }
        var digest = ""
        if let at = ref.firstIndex(of: "@") {
            digest = String(ref[at...])
            ref = String(ref[..<at])
        }
        var parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first else { return ref.lowercased() }
        let hasDomain = parts.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        if !hasDomain {
            parts.insert("docker.io", at: 0)
        }
        if parts[0] == "index.docker.io" || parts[0] == "registry-1.docker.io" {
            parts[0] = "docker.io"
        }
        if parts[0] == "docker.io" && parts.count == 2 {
            parts.insert("library", at: 1)
        }
        var name = parts.joined(separator: "/")
        let last = parts[parts.count - 1]
        if digest.isEmpty && !last.contains(":") {
            name += ":latest"
        }
        return (name + digest).lowercased()
    }

    /// "nginx:1.27" becomes "docker.io/library/nginx".
    static func repository(_ raw: String) -> String {
        var ref = normalize(raw)
        if let at = ref.firstIndex(of: "@") {
            ref = String(ref[..<at])
        }
        if let slash = ref.lastIndex(of: "/"), let colon = ref[slash...].lastIndex(of: ":") {
            ref = String(ref[..<colon])
        }
        return ref
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let left = normalize(a)
        return !left.isEmpty && left == normalize(b)
    }
}

/// Cleans and appends streamed output lines.
enum ResourceLog {
    static let maxLines = 4000

    /// Removes terminal color codes and trailing spaces. nil for empty lines.
    static func clean(_ line: String) -> String? {
        let stripped = line
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Appends a cleaned line. A pull progress line replaces the one before it
    /// when both belong to the same step, so the log does not fill with updates.
    static func append(_ line: String, to lines: inout [String]) {
        guard let clean = clean(line) else { return }
        if let last = lines.last, PullProgress.isSameStep(last, clean) {
            lines[lines.count - 1] = clean
        } else {
            lines.append(clean)
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}

/// A thin bar and one line of text for `image pull` progress.
struct PullProgressBar: View {
    let progress: PullProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
                    .tint(DS.accent)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DS.accent)
            }
            if let progress {
                Text(Self.caption(progress))
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    static func caption(_ progress: PullProgress) -> String {
        var text = "Step \(progress.step) of \(progress.totalSteps): \(progress.title)"
        if let percent = progress.percent { text += " \(Int(percent))%" }
        if let detail = progress.detail { text += ", \(detail)" }
        return text
    }
}

/// Monospaced output that follows new lines, with a copy button.
struct ResourceLogView: View {
    let lines: [String]
    var placeholder: String = "Output shows here."

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if lines.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(DS.textSecondary)
                    }
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .padding(.trailing, 28)
            }
            .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                } label: {
                    DeckIcon(.copy, size: 13, color: DS.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Copy output")
                .padding(8)
                .disabled(lines.isEmpty)
            }
            .onChange(of: lines) { _, newLines in
                guard !newLines.isEmpty else { return }
                proxy.scrollTo(newLines.count - 1, anchor: .bottom)
            }
        }
    }
}

/// The CLI command for an action, shown only when command hints are on.
struct ResourceCommandHint: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true
    let arguments: [String]
    var prefix: String = ""

    init(_ arguments: [String], prefix: String = "") {
        self.arguments = arguments
        self.prefix = prefix
    }

    var body: some View {
        if showHints, let client = state.client {
            CommandHint(prefix + client.commandLine(arguments))
        }
    }
}

/// A key and value pair edited in a sheet (labels, build args).
struct ResourcePair: Identifiable, Hashable {
    let id = UUID()
    var key = ""
    var value = ""
}

/// Rows of key and value fields with add and remove buttons.
struct ResourcePairEditor: View {
    @Binding var rows: [ResourcePair]
    var keyPrompt = "Key"
    var valuePrompt = "Value"
    var addTitle = "Add"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    TextField(keyPrompt, text: field(row.id, \.key))
                        .textFieldStyle(.roundedBorder)
                    Text("=").foregroundStyle(DS.textSecondary)
                    TextField(valuePrompt, text: field(row.id, \.value))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        DeckIcon(.close, size: 12)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
            Button {
                rows.append(ResourcePair())
            } label: {
                DeckLabel(addTitle, icon: .add)
            }
            .buttonStyle(.borderless)
        }
    }

    private func field(_ id: UUID, _ keyPath: WritableKeyPath<ResourcePair, String>) -> Binding<String> {
        Binding(
            get: { rows.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let index = rows.firstIndex(where: { $0.id == id }) {
                    rows[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    /// Filled rows as a dictionary. Empty keys are skipped.
    static func dictionary(_ rows: [ResourcePair]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = row.value }
        }
        return result
    }
}

/// Inline error text with an icon.
struct ResourceErrorText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            DeckIcon(.error, size: 13, color: DS.danger)
            Text(message)
                .font(.callout)
                .foregroundStyle(DS.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Inline warning text with an icon.
struct ResourceWarningText: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            DeckIcon(.warning, size: 13, color: DS.warning)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown on resource screens when the container tool is missing.
struct ResourceToolMissing: View {
    @Environment(AppState.self) private var state
    let icon: DeckIconName

    var body: some View {
        EmptyState(
            icon: icon,
            title: "Container tool not found",
            message: "Install Apple's container tool to use this screen.",
            actionTitle: "Open Setup"
        ) {
            state.showSetup = true
        }
    }
}

/// Container lookups shared by resource screens.
@MainActor
enum ResourceUsage {
    /// Label put on helper containers that the app starts for itself.
    static let helperLabel = "deck.helper"

    static func isHelper(_ container: ContainerSummary) -> Bool {
        container.labels[helperLabel] != nil
    }

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "linux/arm64" becomes "arm64".
    static func shortPlatform(_ platform: String) -> String {
        platform.hasPrefix("linux/") ? String(platform.dropFirst("linux/".count)) : platform
    }

    /// Opens another sheet after the current one has closed.
    static func afterSheetCloses(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            action()
        }
    }
}

// MARK: - Automation

extension View {
    /// Runs the handler for automation commands that DebugAutomation forwards (only active in automation mode).
    func onDeckDebugCommand(_ handler: @escaping (_ name: String, _ value: String) -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .deckDebugCommand)) { note in
            let name = note.userInfo?["name"] as? String ?? ""
            let value = note.userInfo?["value"] as? String ?? ""
            handler(name, value)
        }
    }
}
