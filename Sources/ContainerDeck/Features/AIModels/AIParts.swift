import SwiftUI
import AppKit
import DeckCore

// Small views shared by the AI Models tabs.

extension ModelServerKind {
    /// Closest existing icon for each server kind.
    var deckIcon: DeckIconName {
        switch self {
        case .ollama: return .aiModels
        case .lmStudio: return .sparkle
        case .mlxLM, .oMLX: return .cpu
        case .llamaCpp, .vLLM, .openAICompatible: return .registry
        }
    }
}

extension ModelEndpointStatus {
    var label: String {
        switch self {
        case .running: return "Running"
        case .installed: return "Not running"
        case .notResponding: return "Not answering"
        }
    }

    var tint: Color {
        switch self {
        case .running: return DS.running
        case .installed: return DS.stopped
        case .notResponding: return DS.warning
        }
    }
}

/// Status with a dot, like StatusPill, for any label and color.
struct AIStatusPill: View {
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.75))
        .fixedSize()
    }
}

/// A URL or command in a sunken box with a visible Copy button.
struct AICopyField: View {
    var text: String
    var help: String = "Copy"
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                ResourceUsage.copyToPasteboard(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                DeckLabel(copied ? "Copied" : "Copy", icon: copied ? .success : .copy)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(help)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
    }
}

/// Label column plus content, for cards (same rhythm as DeckFormRow, narrower label).
struct AIRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .frame(width: 118, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum AIFormat {
    static func tokensPerSecond(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: value >= 100 ? "%.0f tok/s" : "%.1f tok/s", value)
    }

    static func seconds(_ value: TimeInterval?) -> String {
        guard let value else { return "-" }
        return value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.1f s", value)
    }

    /// "Mac only", "Containers", "All addresses".
    static func bindText(_ endpoint: ModelEndpoint) -> String {
        guard let bind = endpoint.bindAddress else { return "Unknown" }
        if bind == "*" || bind == "0.0.0.0" || bind == "::" { return "All addresses" }
        return endpoint.reachableFromContainers ? "Containers on \(bind)" : "This Mac only"
    }
}

/// The MLX server's model did not load: plain words, Update or Pick another model, and the raw error under Details.
struct AIModelLoadNotice: View {
    var compact = false
    private var store: AIModelsStore { AIModelsStore.shared }

    var body: some View {
        if let failure = store.mlxLoadFailure, let message = store.mlxFailureMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    DeckIcon(.warning, size: 14, color: DS.warning)
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(DS.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if message.offerUpdate && store.runtime?.isOwnInstall == true {
                        Button {
                            Task {
                                await store.pickAnotherMLXModel()
                                store.installRuntime(upgrade: true)
                            }
                        } label: {
                            DeckLabel("Update MLX Runtime", icon: .download)
                        }
                        .disabled(store.isInstalling)
                    }
                    Button {
                        Task { await store.pickAnotherMLXModel() }
                    } label: {
                        DeckLabel("Pick another model", icon: .aiModels)
                    }
                    .help(store.serverState.isActive ? "Stops the server so you can choose a different model" : "Choose a different model")
                }
                .controlSize(.small)
                if !failure.details.isEmpty && !compact {
                    DetailsDisclosure(text: failure.details.joined(separator: "\n"), maxHeight: 160)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).fill(DS.warning.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.warning.opacity(0.25), lineWidth: 1))
        }
    }
}
