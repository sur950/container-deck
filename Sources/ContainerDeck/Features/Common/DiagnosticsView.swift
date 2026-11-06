import SwiftUI
import AppKit
import DeckCore

/// Versions, backend, kernel, Rosetta, disk and recent errors in one place, with
/// "Copy Diagnostics" for bug reports. The copied text has no secrets.
struct DiagnosticsView: View {
    @Environment(AppState.self) private var state

    @State private var report: DiagnosticsReport?
    @State private var loading = false
    @State private var showSteps = false
    @State private var copied = false

    var body: some View {
        Group {
            if let report {
                content(report)
            } else {
                LoadingView("Collecting diagnostics", style: .logo)
            }
        }
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .task { await load() }
        .sheet(isPresented: $showSteps) {
            if let report {
                VersionMismatchSheet(compatibility: report.compatibility)
                    .environment(state)
                    .tint(DS.accent)
            }
        }
        .onDeckDebugCommand { name, _ in
            if name == "diagnostics-steps" { showSteps = true }
        }
    }

    private func content(_ report: DiagnosticsReport) -> some View {
        DeckPage {
            header(report)
            if report.compatibility.hasIssue {
                VersionIssueCard(compatibility: report.compatibility) { showSteps = true }
            }
            EqualHeightRow {
                MetricTile(title: "App", value: DiagnosticsInfo.appVersion, subtitle: "build \(DiagnosticsInfo.appBuild)", icon: .sparkle)
                MetricTile(title: "Container", value: versionValue(report), subtitle: report.value("Service").map { "service \($0.lowercased())" } ?? "service unknown",
                           icon: .containers, tint: tint(for: report.compatibility))
                MetricTile(title: "Backend", value: report.value("Backend") == "Direct API" ? "Direct" : "Command",
                           subtitle: report.value("Backend") == "Direct API" ? "XPC to the service" : "container CLI", icon: .link)
                MetricTile(title: "Free space", value: freeValue(report), subtitle: "on the data volume", icon: .disk)
            }
            let rows = Self.balancedRows(report.sections)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                EqualHeightRow {
                    sectionCard(row[0])
                    if row.count > 1 {
                        sectionCard(row[1])
                    } else {
                        errorsCard(report)
                    }
                }
            }
            if report.sections.count % 2 == 0 {
                errorsCard(report)
            }
        }
    }

    private func header(_ report: DiagnosticsReport) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(.inspect, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text("Diagnostics").font(.title2.weight(.semibold))
                Text("Collected \(report.date.formatted(date: .omitted, time: .shortened)). Copy it into a bug report. Paths in your home folder and anything that looks like a password or token are left out.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            RefreshButton(help: "Collect again") { await load() }
            Button {
                copy(report)
            } label: {
                DeckLabel(copied ? "Copied" : "Copy Diagnostics", icon: copied ? .success : .copy)
            }
            .deckPrimary()
            .fixedSize()
            Button {
                if let url = URL(string: AppConfig.issuesURL) { NSWorkspace.shared.open(url) }
            } label: {
                DeckLabel("Report a Bug", icon: .openExternal)
            }
            .fixedSize()
        }
    }

    private func sectionCard(_ section: DiagnosticsReport.Section) -> some View {
        Card(section.title, icon: icon(for: section.title)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.items) { item in
                    KeyValueRow(item.key) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if item.level == .warning || item.level == .problem {
                                DeckIcon(item.level == .problem ? .error : .warning, size: 11,
                                         color: item.level == .problem ? DS.danger : DS.warning)
                            }
                            Text(item.value)
                                .font(.callout)
                                .foregroundStyle(DS.textPrimary)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private func errorsCard(_ report: DiagnosticsReport) -> some View {
        Card("Recent errors", icon: .error) {
            if report.errors.isEmpty {
                CardEmptyText("No errors since \(AppConfig.appName) opened")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.errors.suffix(8).reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.date.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(DS.textTertiary)
                                if let source = entry.source {
                                    Pill(source, tint: DS.stopped)
                                }
                            }
                            Text(entry.message)
                                .font(.callout)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }
                    Button("Clear") {
                        DiagnosticsLog.shared.clear()
                        Task { await load() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Helpers

    /// Pairs cards of about the same height so no card in a row is half empty.
    /// Rows keep the order of their first card. An odd card out goes last, with Recent errors.
    static func balancedRows(_ sections: [DiagnosticsReport.Section]) -> [[DiagnosticsReport.Section]] {
        func lines(_ section: DiagnosticsReport.Section) -> Int {
            section.items.reduce(0) { $0 + 1 + $1.value.count / 48 }
        }
        let indexed = sections.enumerated().map { (index: $0.offset, section: $0.element) }
        let bySize = indexed.sorted { lines($0.section) == lines($1.section) ? $0.index < $1.index : lines($0.section) < lines($1.section) }
        var rows: [[(index: Int, section: DiagnosticsReport.Section)]] = []
        // With an odd count the smallest card goes last, next to Recent errors.
        let start = bySize.count % 2
        for index in stride(from: start, to: bySize.count, by: 2) {
            rows.append([bySize[index], bySize[index + 1]].sorted { $0.index < $1.index })
        }
        rows.sort { ($0.first?.index ?? 0) < ($1.first?.index ?? 0) }
        if start == 1 { rows.append([bySize[0]]) }
        return rows.map { $0.map(\.section) }
    }

    private func versionValue(_ report: DiagnosticsReport) -> String {
        guard let text = report.value("Container command") else { return "-" }
        return text.split(separator: " ").first.map(String.init) ?? text
    }

    private func freeValue(_ report: DiagnosticsReport) -> String {
        guard let text = report.value("Free space") else { return "-" }
        return text.replacingOccurrences(of: ", low", with: "")
    }

    private func tint(for compatibility: VersionCompatibility) -> Color {
        switch compatibility.verdict {
        case .supported: return DS.accent
        case .tooOld, .serviceMismatch: return DS.danger
        default: return DS.warning
        }
    }

    private func icon(for title: String) -> DeckIconName {
        switch title {
        case "App": return .sparkle
        case "Container platform": return .containers
        case "Kernel and Rosetta": return .kernel
        case "Disk": return .disk
        case "Setup checks": return .checklist
        default: return .info
        }
    }

    private func copy(_ report: DiagnosticsReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text(), forType: .string)
        copied = true
        state.showToast("Copied diagnostics. No secrets included.", style: .success)
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        let backend = await state.router?.status()
        let context = DiagnosticsContext(
            appVersion: DiagnosticsInfo.appVersion,
            appBuild: DiagnosticsInfo.appBuild,
            cliPath: state.report.cliPath,
            backend: backend,
            setupChecks: state.report.checks,
            errors: DiagnosticsInfo.errors(state: state)
        )
        let fresh = await DiagnosticsCollector.collect(client: state.client, context: context)
        withAnimation(.easeInOut(duration: 0.2)) { report = fresh }
        loading = false
    }
}

/// App facts for Diagnostics.
enum DiagnosticsInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }

    /// Logged errors, plus the last setup error when the log does not have it yet.
    @MainActor
    static func errors(state: AppState) -> [DiagnosticsLog.Entry] {
        var list = DiagnosticsLog.shared.entries
        if let last = state.lastError, !list.contains(where: { $0.message == last }) {
            list.append(DiagnosticsLog.Entry(message: last, source: "Setup"))
        }
        return list
    }
}

/// Short note with a link to the full steps.
struct VersionIssueCard: View {
    let compatibility: VersionCompatibility
    let showSteps: () -> Void

    var body: some View {
        let tint = compatibility.needsScreen ? DS.danger : DS.warning
        HStack(alignment: .center, spacing: 12) {
            DeckIcon(compatibility.needsScreen ? .error : .warning, size: 18, color: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(compatibility.title).font(.callout.weight(.semibold))
                Text(compatibility.message)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Show Steps", action: showSteps)
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Opens Diagnostics in its own window. For a menu command or the palette.
@MainActor
enum DiagnosticsWindow {
    static func show(state: AppState) {
        DeckAuxWindow.show(id: "diagnostics", title: "Diagnostics", size: NSSize(width: 980, height: 760)) {
            DiagnosticsView()
                .environment(state)
                .tint(DS.accent)
                .frame(minWidth: 880, minHeight: 620)
        }
    }

    /// The version mismatch screen in a window (preview and support).
    static func showVersion(_ compatibility: VersionCompatibility, state: AppState) {
        DeckAuxWindow.show(id: "version", title: compatibility.title, size: NSSize(width: 760, height: 700)) {
            VersionMismatchView(compatibility: compatibility)
                .environment(state)
                .tint(DS.accent)
                .frame(minWidth: 680, minHeight: 600)
        }
    }
}

/// One extra window per id, reused when open.
@MainActor
enum DeckAuxWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show<Content: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        if let existing = windows[id] {
            existing.contentViewController = NSHostingController(rootView: content())
            existing.title = title
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let made = NSWindow(contentViewController: NSHostingController(rootView: content()))
        made.title = title
        made.setContentSize(size)
        made.styleMask.insert([.resizable, .closable, .miniaturizable])
        made.isReleasedWhenClosed = false
        made.identifier = NSUserInterfaceItemIdentifier(id)
        made.center()
        windows[id] = made
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: made, queue: .main) { _ in
            MainActor.assumeIsolated { windows[id] = nil }
        }
        made.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
