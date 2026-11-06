import SwiftUI
import AppKit
import DeckCore

/// API keys for hosted providers, kept in the Keychain. Never shown again after saving.
struct ProviderKeysPane: View {
    let store: AgentsStore

    var body: some View {
        DeckPage(maxWidth: 820) {
            SectionHeader("API keys", subtitle: "Kept in your Keychain. Sandboxes get a key only when you turn it on for that sandbox.", icon: .key)
            ForEach(HostedProvider.allCases) { provider in
                ProviderKeyCard(store: store, provider: provider)
            }
            signIns
        }
    }

    @ViewBuilder
    private var signIns: some View {
        let tools = store.tools.filter { $0.installed && $0.tool.provider != nil }
        if !tools.isEmpty {
            Card("Agent sign in", icon: .agents) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tools) { tool in
                        HStack {
                            Text(tool.tool.title)
                            Spacer(minLength: 8)
                            if let signIn = tool.signIn {
                                Pill(signIn, tint: DS.running)
                            } else {
                                Pill("Not detected", tint: DS.stopped)
                            }
                        }
                    }
                    Text("Read from each tool's own files. Tokens are never read or copied.")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct ProviderKeyCard: View {
    @Environment(AppState.self) private var state
    let store: AgentsStore
    let provider: HostedProvider
    @State private var draft = ""
    @State private var editing = false
    @State private var check: KeyCheckResult?
    @State private var checking = false
    @State private var confirmRemove = false

    private var saved: Bool { store.savedProviders.contains(provider) }

    var body: some View {
        Card(provider.title, icon: .key) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(provider.environmentVariable).font(.callout.monospaced()).foregroundStyle(DS.textSecondary)
                    Pill(saved ? "Saved in Keychain" : "Not set", tint: saved ? DS.running : DS.stopped)
                    if let check {
                        Pill(check.title, tint: check == .valid ? DS.running : DS.danger)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if let url = URL(string: provider.consoleURL) { NSWorkspace.shared.open(url) }
                    } label: {
                        DeckLabel("Get a Key", icon: .openExternal)
                    }
                    .buttonStyle(.borderless)
                }
                if editing || !saved {
                    HStack(spacing: 8) {
                        SecureField("Key", text: $draft, prompt: Text(provider.keyPlaceholder))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .onSubmit(save)
                        Button("Save", action: save)
                            .deckPrimary()
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if saved {
                            Button("Cancel") { editing = false; draft = "" }
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button {
                            runCheck()
                        } label: {
                            DeckLabel("Check Key", icon: .checklist)
                        }
                        .disabled(checking)
                        if checking { ProgressView().controlSize(.small) }
                        Button("Replace…") { editing = true }
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            DeckLabel("Remove", icon: .trash)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Remove the \(provider.title) key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) { remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is deleted from your Keychain.")
        }
    }

    private func save() {
        let key = draft
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            do {
                try await store.saveKey(key, for: provider)
                draft = ""
                editing = false
                check = nil
                state.showToast("Saved the \(provider.title) key", style: .success)
            } catch {
                state.showError(error)
            }
        }
    }

    private func remove() {
        Task {
            do {
                try await store.removeKey(provider)
                check = nil
                state.showToast("Removed the \(provider.title) key")
            } catch {
                state.showError(error)
            }
        }
    }

    private func runCheck() {
        checking = true
        Task {
            check = await store.checkKey(provider)
            checking = false
        }
    }
}
