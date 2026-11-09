import SwiftUI
import AppKit
import DeckCore

/// The one popup for system tool updates: a newer Apple container (never blocked), shown as a sheet over
/// the main window after the launch check. Other tools only get the quiet Dashboard notice.
///
/// At most once per version per launch. Never during first run setup, over another sheet, for an
/// update the app can't run, after Skip This Version, or in automation mode
/// (unless the `components-prompt` debug command asks).
@MainActor
enum PlatformUpdatePrompt {
    static let skippedKey = "componentsSkippedPlatformVersion"
    private static var shownThisLaunch: Set<String> = []
    private static var sheet: NSWindow?
    /// The open prompt's buttons, for the `components-prompt-choose` debug command.
    private static var choose: ((PlatformUpdatePromptView.Choice) -> Void)?

    static func debugChoose(_ value: String) {
        switch value {
        case "update": choose?(.update)
        case "skip": choose?(.skip)
        default: choose?(.later)
        }
    }

    static func presentIfNeeded(_ row: ComponentInfo?, state: AppState?, force: Bool = false) {
        guard let row, let state, row.kind == .container, row.status == .updateAvailable, row.canUpdateInApp,
              let target = row.target else { return }
        guard sheet == nil, let window = MainWindow.existing, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        if !force {
            guard !DebugAutomation.isEnabled else { return }
            guard state.setupCompleted, !state.showSetup, state.runRequest == nil, state.buildRequest == nil, !state.showPalette else { return }
            guard UserDefaults.standard.string(forKey: skippedKey) != target, !shownThisLaunch.contains(target) else { return }
        }
        shownThisLaunch.insert(target)

        let running = BackgroundServices.shared.containers.filter(\.isRunning).count
        let handler: (PlatformUpdatePromptView.Choice) -> Void = { choice in
            dismiss(from: window)
            choose = nil
            switch choice {
            case .update:
                ComponentsCenter.shared.openSettingsTab()
                Task { await ComponentsCenter.shared.update(row, confirm: false) }
            case .later:
                break
            case .skip:
                UserDefaults.standard.set(target, forKey: skippedKey)
            }
        }
        choose = handler
        let view = PlatformUpdatePromptView(row: row, runningCount: running, onChoice: handler)
        let host = NSHostingController(rootView: view.environment(state))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        panel.setContentSize(host.view.fittingSize)
        sheet = panel
        window.beginSheet(panel)
    }

    private static func dismiss(from window: NSWindow) {
        guard let panel = sheet else { return }
        window.endSheet(panel)
        sheet = nil
    }
}

struct PlatformUpdatePromptView: View {
    enum Choice { case update, later, skip }

    let row: ComponentInfo
    let runningCount: Int
    let onChoice: (Choice) -> Void

    var body: some View {
        SheetScaffold("Apple container \(row.target ?? "") is ready",
                      subtitle: "You have \(row.installed ?? "an older version"). " + PlatformUpdatePromptView.testedLine(row),
                      icon: .containers, width: 520, scrolls: false) {
            if !row.notesSummary.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What is new")
                        .font(.callout.weight(.semibold))
                    ForEach(Array(row.notesSummary.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(DS.accent).frame(width: 4, height: 4)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(DS.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let notes = row.notesURL {
                        Button {
                            NSWorkspace.shared.open(notes)
                        } label: {
                            Text("Full release notes").font(.callout)
                        }
                        .deckLink()
                        // A sheet focuses its first control. A ring on the link looked like a stray box.
                        .focusEffectDisabled()
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                DeckIcon(.warning, size: 15, color: DS.warning)
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.warning.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.warning.opacity(0.25), lineWidth: 1))
        } footer: {
            Button("Skip This Version") { onChoice(.skip) }
            Button("Later") { onChoice(.later) }
                .keyboardShortcut(.cancelAction)
            Button("Update Now") { onChoice(.update) }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
        }
    }

    /// Updates are never blocked. Says whether the new version is the tested one.
    static func testedLine(_ row: ComponentInfo) -> String {
        guard let tested = ComponentGate.tested(for: row.id), let target = row.target.flatMap(ToolVersion.init) else { return "" }
        if tested.matches(target) { return "This version is tested with \(AppConfig.appName)." }
        return "\(AppConfig.appName) is tested with \(tested.text). If a feature stops working, it offers to switch back."
    }

    private var warning: String {
        let containers: String
        switch runningCount {
        case 0: containers = "No containers are running now."
        case 1: containers = "1 running container stops during the update."
        default: containers = "\(runningCount) running containers stop during the update."
        }
        return "The container service stops while Apple's installer runs, then starts again. \(containers) macOS asks for your password."
    }
}
