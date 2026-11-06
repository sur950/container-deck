import SwiftUI
import DeckCore

/// Strip at the top of the window when a required check fails.
struct HealthBanner: View {
    @Environment(AppState.self) private var state
    let issue: SetupCheck

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(DS.warning.opacity(0.16))
                DeckIcon(.warning, size: 16, color: DS.warning)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(issue.title) needs attention")
                    .font(.callout.weight(.semibold))
                Text(issue.state.message)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Open Setup") { state.showSetup = true }
                .deckPrimary()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(DS.warning.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.warning.opacity(0.25)).frame(height: 1)
        }
    }
}

/// One setup check with its status and fix button.
struct CheckRow: View {
    @Environment(AppState.self) private var state
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(state: check.state)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.title).font(.body.weight(.medium))
                    if check.isOptional {
                        Pill("Optional", tint: DS.textSecondary)
                    }
                }
                Text(check.state.message)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let fix = check.fix {
                if state.busyFix == fix {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        if check.id == .cliInstalled {
                            Button(FixAction.chooseBinary.title) {
                                Task { await state.fix(.chooseBinary) }
                            }
                        }
                        Button {
                            Task { await state.fix(fix) }
                        } label: {
                            DeckLabel(fix.title, icon: fix.needsAdmin ? .lock : .wand)
                        }
                        .deckPrimary()
                    }
                    .disabled(state.busyFix != nil)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// Status of one setup check.
struct StatusIcon: View {
    let state: CheckState

    var body: some View {
        switch state {
        case .ok:
            DeckIcon(.success, size: 20, color: DS.running)
        case .warning:
            DeckIcon(.warning, size: 20, color: DS.warning)
        case .missing:
            DeckIcon(.pending, size: 20, color: DS.warning)
        case .failed:
            DeckIcon(.error, size: 20, color: DS.danger)
        case .waiting:
            DeckIcon(.waiting, size: 20, color: DS.textSecondary)
        }
    }
}

/// Shows the last error from a fix, if any.
struct ErrorNote: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DeckIcon(.error, size: 16, color: DS.danger)
                .padding(.top, 1)
            Text(message)
                .font(.callout)
                .foregroundStyle(DS.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.danger.opacity(0.25), lineWidth: 1))
    }
}

/// Brand tinted button: soft red fill, red text. For secondary actions inside cards. Use it instead of Menu labels, which can render blank.
struct SoftAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(DS.accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DS.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(DS.accent.opacity(0.22), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

/// Plain red text link, used for "Show All" in card headers.
struct AccentLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(DS.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
