import SwiftUI
import AppKit
import DeckCore

/// Status words and colors for a provider, shared by the card and the picker.
enum ProviderStatus {
    case checking, ready, needsSetup, notInstalled, blocked

    init(_ readiness: ShareReadiness?, blocker: ShareFailure? = nil) {
        switch readiness {
        case nil: self = .checking
        case .notInstalled: self = .notInstalled
        case .needsSetup: self = .needsSetup
        case .ready: self = blocker == nil ? .ready : .blocked
        }
    }

    var title: String {
        switch self {
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .needsSetup: return "Needs setup"
        case .notInstalled: return "Not installed"
        case .blocked: return "Not for this route"
        }
    }

    var tint: Color {
        switch self {
        case .ready: return DS.running
        case .needsSetup, .blocked: return DS.warning
        case .checking, .notInstalled: return DS.stopped
        }
    }
}

/// One provider: name, one line of status or fix, a status pill and the action that helps.
/// Knows nothing about any single provider. Everything comes from `ShareProvider`.
struct ProviderStatusRow: View {
    let provider: any ShareProvider
    let store: DomainsStore
    var route: ProxyRoute? = nil
    var isSelected: Bool? = nil
    let onSetup: () -> Void
    let onError: (Error) -> Void

    private var readiness: ShareReadiness? { store.readiness(of: provider) }
    private var blocker: ShareFailure? { route.flatMap { store.blocker($0, provider) } }
    private var status: ProviderStatus { ProviderStatus(readiness, blocker: blocker) }

    private var detail: String {
        switch readiness {
        case .ready(let detail): return blocker.map { $0.errorDescription ?? $0.message } ?? detail
        case .needsSetup(let failure): return failure.errorDescription ?? failure.message
        case .notInstalled: return provider.summary
        case nil: return provider.summary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let isSelected {
                DeckIcon(isSelected ? .success : .pending, size: 14, color: isSelected ? DS.accent : DS.textTertiary)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
            Pill(status.title, tint: status.tint)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var action: some View {
        switch readiness {
        case .notInstalled:
            if store.installing.contains(provider.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu("Install") {
                    ForEach(store.installOptions(for: provider)) { option in
                        Button(option.title) {
                            Task {
                                do { try await store.install(provider, option: option) } catch { onError(error) }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(provider.installOptions.compactMap(\.command).first.map { "Runs \($0) when you pick it. Nothing installs on its own." }
                      ?? "Opens the download page")
            }
        case .needsSetup(let failure):
            if failure.opensSetup && !provider.setupFields.isEmpty {
                Button("Set Up", action: onSetup).controlSize(.small)
            } else if let link = failure.link {
                Button("Fix") { NSWorkspace.shared.open(link) }
                    .controlSize(.small)
                    .help(link.absoluteString)
            }
        case .ready:
            if !provider.setupFields.isEmpty {
                Button(action: onSetup) { DeckIcon(.key, size: 12) }
                    .buttonStyle(.borderless)
                    .help("Change \(provider.title) settings")
            }
        case nil:
            EmptyView()
        }
    }
}

/// The Share popover on a route: every provider with its status, the last one used picked.
struct SharePickerPopover: View {
    let route: ProxyRoute
    let store: DomainsStore
    let onShare: (any ShareProvider) -> Void
    let onSetup: (any ShareProvider) -> Void
    let onError: (Error) -> Void
    @State private var selectedID: String?

    private var selected: (any ShareProvider)? {
        selectedID.flatMap(ShareProviders.provider(id:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share \(route.host)").font(.headline)
                Text("Anyone with the link can open it. Pick a provider your network allows.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Divider() }
                    let usable = store.canShare(route, with: provider)
                    ProviderStatusRow(provider: provider, store: store, route: route,
                                      isSelected: selectedID == provider.id,
                                      onSetup: { onSetup(provider) }, onError: onError)
                        .opacity(usable ? 1 : 0.75)
                        .onTapGesture { if usable { selectedID = provider.id } }
                }
            }
            HStack {
                Spacer()
                Button(selected.map { "Share with \($0.title)" } ?? "Share") {
                    if let selected { onShare(selected) }
                }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(selected.map { !store.canShare(route, with: $0) } ?? true)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { selectedID = store.preferredProvider(for: route)?.id }
    }
}

/// Setup values for one provider, like the ngrok authtoken. Built from the provider's fields.
/// Secrets go to the Keychain and reach the tool only through its environment.
struct ShareSetupSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let provider: any ShareProvider
    @State private var values: [String: String] = [:]
    @State private var isSaving = false

    private var store: DomainsStore { DomainsStore.shared }
    private var hasSavedSecret: Bool { provider.setupFields.contains { store.hasSecret(provider, $0) } }

    private func problem(_ field: ShareSetupField) -> String? {
        provider.validate(field: field, value: values[field.key] ?? "")
    }

    private var canSave: Bool {
        guard !isSaving, provider.setupFields.allSatisfy({ problem($0) == nil }) else { return false }
        return provider.setupFields.filter { !$0.isOptional }.allSatisfy { field in
            !(values[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || store.hasSecret(provider, field)
                || store.readiness(of: provider)?.isReady == true
        }
    }

    var body: some View {
        SheetScaffold(provider.title, subtitle: "Settings for sharing with \(provider.title)", icon: .key) {
            DeckFormGroup {
                ForEach(provider.setupFields) { field in
                    DeckFormRow(field.title, note: note(for: field)) {
                        input(for: field)
                    }
                }
            }
            ForEach(provider.setupFields) { field in
                if let problem = problem(field) { ResourceWarningText(problem) }
            }
            HStack(spacing: 6) {
                DeckIcon(.lock, size: 12, color: DS.textSecondary)
                Text("Secrets stay in your Keychain. The tool gets them only while a share runs, never in a file.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            if let link = provider.setupLink {
                Button("Open the \(provider.title) dashboard") { NSWorkspace.shared.open(link) }
                    .deckLink()
                    .font(.callout)
            }
        } footer: {
            if hasSavedSecret {
                Button("Remove Saved Token", role: .destructive) { remove() }
            }
            Spacer()
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .onAppear {
            for field in provider.setupFields where !field.isSecret {
                values[field.key] = store.setupValue(provider, field)
            }
        }
    }

    private func note(for field: ShareSetupField) -> String {
        field.isSecret && store.hasSecret(provider, field) ? "A value is saved. Paste a new one to replace it." : field.note
    }

    @ViewBuilder
    private func input(for field: ShareSetupField) -> some View {
        let binding = Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 })
        let prompt = Text(field.isSecret && store.hasSecret(provider, field) ? "Saved in Keychain" : field.placeholder)
        if field.isSecret {
            SecureField(field.title, text: binding, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.body.monospaced())
                .onSubmit(save)
        } else {
            TextField(field.title, text: binding, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit(save)
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        Task {
            do {
                try await store.saveSetup(provider, values: values)
                state.showToast("\(provider.title) settings saved", style: .success)
                dismiss()
            } catch {
                state.showError(error)
            }
            isSaving = false
        }
    }

    private func remove() {
        Task {
            do {
                try await store.removeSecrets(provider)
                dismiss()
            } catch {
                state.showError(error)
            }
        }
    }
}
