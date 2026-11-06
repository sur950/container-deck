import SwiftUI
import DeckCore

/// Local DNS domains so containers can be reached by name, like web.test.
struct DNSSettings: View {
    @Environment(AppState.self) private var state

    @State private var domains: [String] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var newDomain = ""
    @State private var isCreating = false
    @State private var pendingDelete: String?
    @State private var defaultDomain: String?
    /// Default domain the running service uses. Differs from `defaultDomain`
    /// after a change that waits for a restart.
    @State private var activeDefaultDomain: String?
    @State private var canSetDefault = false
    @State private var isSavingDefault = false
    @State private var showRestart = false
    @State private var isRestarting = false

    /// System property that holds the default DNS domain (`[dns] domain` in config.toml).
    static let defaultDomainKey = "dns.domain"

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 10) {
                    DeckIcon(.dns, size: 18, color: DS.accent)
                    Text(verbatim: "Containers get names like web.test, so you can open http://web.test in your browser.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if state.client == nil {
                    Text("Install Apple's container tool to manage DNS domains.")
                        .foregroundStyle(.secondary)
                } else if domains.isEmpty && !isLoading {
                    Text("No local domains yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(domains, id: \.self) { domain in
                    HStack(spacing: 8) {
                        Text(domain).font(.body.monospaced())
                        if domain == defaultDomain {
                            Pill("Default", tint: DS.running)
                        }
                        Spacer()
                        if canSetDefault && domain != defaultDomain {
                            Button("Make Default") { setDefault(domain) }
                                .disabled(isSavingDefault)
                        }
                        Button(role: .destructive) {
                            pendingDelete = domain
                        } label: {
                            DeckIcon(.trash, size: 13)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete \(domain)")
                    }
                }
                if let loadError {
                    ResourceErrorText(loadError)
                }
            } header: {
                HStack {
                    Text("Local domains")
                    Spacer()
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section {
                LabeledContent("New domain") {
                    HStack(spacing: 8) {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        }
                        TextField("New domain", text: $newDomain, prompt: Text("test"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: 220)
                            .onSubmit(create)
                        Button("Create", action: create)
                            .deckPrimary()
                            .disabled(!newDomainIsValid || isCreating || state.client == nil)
                    }
                }
                if !trimmedNewDomain.isEmpty && !newDomainIsValid {
                    ResourceWarningText("Use lowercase letters, numbers and dashes, like test or dev.local.")
                }
                HStack(spacing: 6) {
                    DeckIcon(.lock, size: 12, color: DS.textSecondary)
                    Text("macOS asks for your admin password to add or remove a domain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ResourceCommandHint(["system", "dns", "create", trimmedNewDomain.isEmpty ? "test" : trimmedNewDomain], prefix: "sudo ")
            } header: {
                Text("Add a domain")
            }

            Section {
                if canSetDefault {
                    LabeledContent("Default domain") {
                        Text(defaultDomain ?? "Not set")
                            .font(defaultDomain == nil ? .body : .body.monospaced())
                            .foregroundStyle(defaultDomain == nil ? Color.secondary : Color.primary)
                    }
                    if defaultDomain != activeDefaultDomain {
                        ResourceWarningText("Saved. Restart the container service to use it.")
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            if isRestarting {
                                ProgressView().controlSize(.small)
                            }
                            Button("Restart Service") { showRestart = true }
                                .disabled(isRestarting || state.client == nil)
                        }
                    } label: {
                        Text("Apply a change")
                        Text("New containers get names in the default domain.")
                    }
                } else {
                    Text("This version of the container tool cannot set the default domain from here. Set domain under [dns] in ~/.config/container/config.toml, then restart the service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Default domain")
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .task(id: state.resourcesVersion) { await load() }
        .alert("Delete \(pendingDelete ?? "")?", isPresented: deleteShown, presenting: pendingDelete) { domain in
            Button("Delete", role: .destructive) { delete(domain) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Containers can no longer be reached by names in this domain. macOS asks for your admin password.")
        }
        .confirmationDialog("Restart the container service?", isPresented: $showRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { restartService() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running containers stop.")
        }
    }

    // MARK: - Values

    private var trimmedNewDomain: String {
        newDomain.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var newDomainIsValid: Bool {
        let pattern = "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"
        return trimmedNewDomain.range(of: pattern, options: .regularExpression) != nil
    }

    private var deleteShown: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { shown in if !shown { pendingDelete = nil } }
        )
    }

    /// Strips quotes and treats empty or "nil" as not set.
    static func cleanDomainValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        if value.isEmpty || value == "nil" || value == "null" || value == "<nil>" || value == "*undefined*" {
            return nil
        }
        return value
    }

    // MARK: - Actions

    private func load() async {
        guard let client = state.client else { return }
        isLoading = true
        do {
            domains = try await client.dnsDomains().sorted()
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        do {
            let properties = try await client.systemProperties()
            canSetDefault = true
            let active = Self.cleanDomainValue(properties.first { $0.key == Self.defaultDomainKey }?.value)
            activeDefaultDomain = active
            // The service reads config.toml only when it starts, so a saved change shows from the file.
            defaultDomain = Self.cleanDomainValue(SystemConfigFile.value(Self.defaultDomainKey)) ?? active
        } catch {
            if !Task.isCancelled {
                canSetDefault = false
                defaultDomain = nil
                activeDefaultDomain = nil
            }
        }
        isLoading = false
    }

    private func create() {
        guard let client = state.client, newDomainIsValid, !isCreating else { return }
        let domain = trimmedNewDomain
        isCreating = true
        Task {
            do {
                try await client.createDNSDomain(domain)
                newDomain = ""
                state.dnsDomain = domain
                state.showToast("Added \(domain)", style: .success)
                await load()
            } catch {
                state.showError(error)
            }
            isCreating = false
        }
    }

    private func delete(_ domain: String) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.deleteDNSDomain(domain)
                state.showToast("Removed \(domain)", style: .success)
                await load()
            } catch {
                state.showError(error)
            }
        }
    }

    private func setDefault(_ domain: String) {
        guard let client = state.client, !isSavingDefault else { return }
        isSavingDefault = true
        Task {
            do {
                try await client.setSystemProperty(Self.defaultDomainKey, value: domain)
                defaultDomain = domain
                state.showToast("Default domain is now \(domain). Restart the service to apply.", style: .success)
            } catch {
                state.showError(error)
            }
            isSavingDefault = false
        }
    }

    private func restartService() {
        guard let client = state.client, !isRestarting else { return }
        Task {
            guard await state.confirmServiceStop(restart: true) else { return }
            BackgroundServices.shared.noteServiceStopping()
            isRestarting = true
            do {
                try await client.restartSystemService()
                state.showToast("The container service restarted", style: .success)
            } catch {
                state.showError(error)
            }
            await state.refresh()
            state.resourcesChanged()
            isRestarting = false
        }
    }
}
