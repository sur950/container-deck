import SwiftUI
import DeckCore

/// Quiet Dashboard notices for system tools, each with one button to Settings, Components:
/// - a tool (not Apple container, which gets a popup) where a feature failed on a version other
///   than the tested one: "The Ollama model list didn't work with Ollama 1.0.0. It works with 0.16.2."
/// - "3 updates available".
/// Close hides a notice until what it shows changes. Nothing shows when there is nothing to say.
struct ComponentsNotice: View {
    @AppStorage(ComponentsNotice.dismissedKey) private var dismissed = ""
    @AppStorage(ComponentsNotice.dismissedHealthKey) private var dismissedHealth = ""
    private let center = ComponentsCenter.shared

    static let dismissedKey = "componentsNoticeDismissed"
    static let dismissedHealthKey = "componentsHealthNoticeDismissed"

    var body: some View {
        let problems = center.toolProblems
        let healthSignature = ComponentsNotice.healthSignature(problems)
        let updates = center.rows.filter { $0.status == .updateAvailable }
        let signature = ComponentsNotice.signature(updates)
        VStack(spacing: 10) {
            if !problems.isEmpty, healthSignature != dismissedHealth {
                notice(icon: .warning, tint: DS.danger,
                       title: ComponentsNotice.healthTitle(problems), detail: ComponentsNotice.healthDetail(problems),
                       button: "Review", help: "Hide until something else changes") {
                    dismissedHealth = healthSignature
                }
            }
            if !updates.isEmpty, signature != dismissed {
                notice(icon: .components, tint: DS.accent,
                       title: updates.count == 1 ? "1 update available" : "\(updates.count) updates available",
                       detail: ComponentsNotice.names(updates), button: "Review Updates", help: "Hide until there is a new update") {
                    dismissed = signature
                }
            }
        }
    }

    private func notice(icon: DeckIconName, tint: Color, title: String, detail: String, button: String, help: String,
                        close: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            IconBadge(icon, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(button) { center.openSettingsTab() }
            Button(action: close) {
                DeckIcon(.close, size: 11, color: DS.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .deckCard()
    }

    /// Changes when an update is added or a newer version shows up.
    static func signature(_ rows: [ComponentInfo]) -> String {
        rows.map { "\($0.id)@\($0.target ?? $0.latest ?? "")" }.sorted().joined(separator: ",")
    }

    /// Changes when another tool or version stops working, or another check fails.
    static func healthSignature(_ rows: [ComponentInfo]) -> String {
        rows.map { "\($0.id)@\($0.installed ?? ""):\($0.failedChecks.map(\.id).sorted().joined(separator: "+"))" }
            .sorted().joined(separator: ",")
    }

    /// "The Ollama model list didn't work with Ollama 1.0.0." or "2 tools have features that didn't work".
    static func healthTitle(_ rows: [ComponentInfo]) -> String {
        if rows.count == 1, let row = rows.first { return ComponentHealthAssessment.headline(row) }
        return "\(rows.count) tools have features that didn't work"
    }

    /// "It works with 0.16.2. Switch from Settings, Components.", or the names of several tools.
    static func healthDetail(_ rows: [ComponentInfo]) -> String {
        if rows.count == 1, let row = rows.first, let target = row.switchTarget {
            return "It works with \(target). Switch from Settings, Components."
        }
        return names(rows) + ". Each works with its tested version."
    }

    /// "Ollama, MLX (mlx-lm) and 2 more".
    static func names(_ rows: [ComponentInfo]) -> String {
        let names = rows.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// The switch offer where a feature failed: "Kubernetes cluster list didn't work with Apple
/// container 1.8.0. It works with 1.7.1." with Switch to 1.7.1. Shows nothing while everything works.
struct ComponentHealthNote: View {
    let kinds: [ComponentKind]
    /// Space around the note, only while it shows.
    var padding = EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16)
    private let center = ComponentsCenter.shared

    var body: some View {
        if let row = center.problem(in: kinds) {
            HStack(spacing: 8) {
                DeckIcon(.warning, size: 12, color: DS.warning)
                Text(ComponentHealthNote.text(row))
                    .font(.callout)
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let target = row.switchTarget {
                    Button(ComponentSwitchPlanner.runsInApp(row) ? "Switch to \(target)" : "How to Switch") {
                        // The progress and the manual steps show in Settings, Components.
                        center.openSettingsTab()
                        Task { await center.switchToTested(row) }
                    }
                    .controlSize(.small)
                    .disabled(center.run?.isRunning == true || center.preparing != nil)
                }
                Button("Components") { center.openSettingsTab() }
                    .deckLink()
                    .help("Open Settings, Components")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.warning.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.warning.opacity(0.25), lineWidth: 1))
            .padding(padding)
        }
    }

    /// "Kubernetes port forwards didn't work with kubectl 2.0.0. It works with 1.35.0."
    static func text(_ row: ComponentInfo) -> String {
        [ComponentHealthAssessment.headline(row), ComponentHealthAssessment.offer(row)].compactMap { $0 }.joined(separator: " ")
    }
}
