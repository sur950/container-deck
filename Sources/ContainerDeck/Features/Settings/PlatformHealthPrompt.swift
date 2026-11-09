import SwiftUI
import AppKit
import DeckCore

/// When to show the Apple container "not working" popup. Pure, so it is unit tested.
struct HealthPromptRules {
    /// Versions shown this launch.
    var shownThisLaunch: Set<String> = []
    /// The version the person said Don't Ask Again for.
    var skippedVersion: String?

    /// Only when a feature failed on a version other than the tested one (never just because a
    /// version is untested). Once per version per launch, never for a skipped version.
    func shouldShow(_ row: ComponentInfo?) -> Bool {
        guard let row, row.kind == .container, row.offersSwitch, let version = row.installed else { return false }
        return version != skippedVersion && !shownThisLaunch.contains(version)
    }

    mutating func noteShown(_ row: ComponentInfo) {
        if let version = row.installed { shownThisLaunch.insert(version) }
    }

    mutating func skip(_ row: ComponentInfo) {
        skippedVersion = row.installed
    }
}

/// The popup for Apple container when a feature the app uses failed with the installed version and
/// that version is not the tested one: what failed, Switch to the tested version, Not Now and
/// Don't Ask Again for this version. Other tools get the quiet Dashboard notice instead.
///
/// Shown as a sheet over the main window after the launch check. Never during first run setup,
/// over another sheet, or in automation mode (unless `components-health-prompt` asks).
@MainActor
enum PlatformHealthPrompt {
    static let skippedKey = "componentsSkippedHealthVersion"
    private static var rules = HealthPromptRules()
    private static var sheet: NSWindow?
    private static var choose: ((PlatformHealthPromptView.Choice) -> Void)?

    static func debugChoose(_ value: String) {
        switch value {
        case "switch", "downgrade": choose?(.switchVersion)
        case "skip": choose?(.skip)
        default: choose?(.later)
        }
    }

    static func presentIfNeeded(_ row: ComponentInfo?, state: AppState?, force: Bool = false) {
        guard let row, let state, row.kind == .container, row.offersSwitch else { return }
        guard sheet == nil, let window = MainWindow.existing, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil else { return }
        if !force {
            guard !DebugAutomation.isEnabled else { return }
            guard state.setupCompleted, !state.showSetup, state.runRequest == nil, state.buildRequest == nil, !state.showPalette else { return }
            rules.skippedVersion = UserDefaults.standard.string(forKey: skippedKey)
            guard rules.shouldShow(row) else { return }
        }
        rules.noteShown(row)

        let running = BackgroundServices.shared.containers.filter(\.isRunning).count
        let handler: (PlatformHealthPromptView.Choice) -> Void = { choice in
            dismiss(from: window)
            choose = nil
            switch choice {
            case .switchVersion:
                ComponentsCenter.shared.openSettingsTab()
                Task { await ComponentsCenter.shared.switchToTested(row, confirm: false) }
            case .later:
                break
            case .skip:
                rules.skip(row)
                UserDefaults.standard.set(row.installed, forKey: skippedKey)
            }
        }
        choose = handler
        let view = PlatformHealthPromptView(row: row, runningCount: running, onChoice: handler)
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

struct PlatformHealthPromptView: View {
    enum Choice { case switchVersion, later, skip }

    let row: ComponentInfo
    let runningCount: Int
    let onChoice: (Choice) -> Void

    var body: some View {
        SheetScaffold(title,
                      subtitle: subtitle, icon: .containers, width: 520, scrolls: false) {
            if !row.failedChecks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not working")
                        .font(.callout.weight(.semibold))
                    ForEach(row.failedChecks) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            DeckIcon(.error, size: 11, color: DS.danger)
                            Text(check.failure)
                                .font(.callout)
                                .foregroundStyle(DS.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .help(check.detail ?? "")
                    }
                }
            }
            if let target = row.switchTarget {
                HStack(alignment: .top, spacing: 10) {
                    DeckIcon(.warning, size: 15, color: DS.warning)
                    Text(warning(target))
                        .font(.callout)
                        .foregroundStyle(DS.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.warning.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.warning.opacity(0.25), lineWidth: 1))
            }
        } footer: {
            Button("Don't Ask Again") { onChoice(.skip) }
                .help("Don't ask again for version \(row.installed ?? "")")
            Button("Not Now") { onChoice(.later) }
                .keyboardShortcut(.cancelAction)
            Button(row.switchTarget.map { "Switch to \($0)" } ?? "Show Steps") { onChoice(.switchVersion) }
                .keyboardShortcut(.defaultAction)
                .deckPrimary()
        }
    }

    /// The headline without its final period, as a sheet title.
    private var title: String {
        let text = ComponentHealthAssessment.headline(row)
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    private var subtitle: String {
        "\(ComponentHealthAssessment.offer(row) ?? "") \(AppConfig.appName) is tested with Apple container \(row.testedText ?? "")."
    }

    private func warning(_ target: String) -> String {
        let containers: String
        switch runningCount {
        case 0: containers = "No containers are running now."
        case 1: containers = "1 running container stops and starts again afterwards."
        default: containers = "\(runningCount) running containers stop and start again afterwards."
        }
        if ComponentSwitchPlanner.isUpgrade(row, to: target) {
            return "The switch stops the container service and installs \(target). Images, volumes and settings are kept. \(containers) macOS asks for your password."
        }
        return "The switch stops the container service, removes \(row.installed ?? "this version") keeping your data, and installs \(target). \(containers) macOS asks for your password. "
            + ComponentSwitchNotes.containerData(from: row.installed ?? "this version", to: target)
    }
}
