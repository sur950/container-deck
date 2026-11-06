import SwiftUI
import DeckCore

/// Adds a container DNS domain, or a host alias that points at this Mac.
struct AddDomainSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var isHostAlias: Bool
    @State private var name: String
    @State private var address = DomainsConfig.hostAliasAddress
    @State private var isSaving = false

    init(startAsHostAlias: Bool) {
        _isHostAlias = State(initialValue: startAsHostAlias)
        _name = State(initialValue: startAsHostAlias ? DomainsConfig.hostAliasName : "")
    }

    private var trimmedName: String { HostName.normalize(name) }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespaces) }
    private var nameIsValid: Bool { LocalDomain.isValidName(trimmedName) }
    private var addressIsValid: Bool { !isHostAlias || LocalDomain.isIPv4(trimmedAddress) }
    private var exists: Bool { DomainsStore.shared.domains.contains { $0.name == trimmedName } }

    var body: some View {
        SheetScaffold(
            isHostAlias ? "Reach This Mac" : "Add Domain",
            subtitle: isHostAlias ? "Containers reach services on this Mac by name" : "Containers get names in this domain",
            icon: isHostAlias ? .link : .dns
        ) {
            Picker("Kind", selection: $isHostAlias) {
                Text("Container names").tag(false)
                Text("This Mac").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: isHostAlias) { _, host in
                if host && trimmedName.isEmpty { name = DomainsConfig.hostAliasName }
                if !host && name == DomainsConfig.hostAliasName { name = "" }
            }

            DeckFormGroup {
                DeckFormRow("Name", note: isHostAlias
                            ? "Containers open http://\(trimmedName.isEmpty ? DomainsConfig.hostAliasName : trimmedName):8000 to reach a server on this Mac."
                            : "A container named web becomes web.\(trimmedName.isEmpty ? "test" : trimmedName).") {
                    TextField("Name", text: $name, prompt: Text(isHostAlias ? DomainsConfig.hostAliasName : "test"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(save)
                }
                if isHostAlias {
                    DeckFormRow("Address", note: "Any unused IPv4 address. macOS sends it to 127.0.0.1 on this Mac.") {
                        TextField("Address", text: $address, prompt: Text(DomainsConfig.hostAliasAddress))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .font(.body.monospaced())
                    }
                }
            }
            if !trimmedName.isEmpty && !nameIsValid {
                ResourceWarningText("Use lowercase letters, numbers, dashes and dots, like test or dev.local.")
            } else if exists {
                ResourceWarningText("\(trimmedName) already exists.")
            }
            if !addressIsValid {
                ResourceWarningText("Use an IPv4 address like 203.0.113.113.")
            }
            if isHostAlias {
                ResourceWarningText("macOS turns off iCloud Private Relay while a host alias exists, and drops its rule after a restart. Add it again after a restart.")
            }
            HStack(spacing: 6) {
                DeckIcon(.lock, size: 12, color: DS.textSecondary)
                Text("macOS asks for your admin password.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            ResourceCommandHint(commandArguments, prefix: "sudo ")
        } footer: {
            if isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isHostAlias ? "Add Host Alias" : "Add Domain", action: save)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || !addressIsValid || exists || isSaving)
        }
    }

    private var commandArguments: [String] {
        var args = ["system", "dns", "create"]
        if isHostAlias { args += ["--localhost", trimmedAddress.isEmpty ? DomainsConfig.hostAliasAddress : trimmedAddress] }
        args.append(trimmedName.isEmpty ? (isHostAlias ? DomainsConfig.hostAliasName : "test") : trimmedName)
        return args
    }

    private func save() {
        guard nameIsValid, addressIsValid, !exists, !isSaving else { return }
        isSaving = true
        let domain = trimmedName
        let host = isHostAlias ? trimmedAddress : nil
        Task {
            do {
                try await DomainsStore.shared.createDomain(domain, hostAddress: host)
                state.showToast("Added \(domain)", style: .success)
                state.resourcesChanged()
                dismiss()
            } catch {
                state.showError(error)
            }
            isSaving = false
        }
    }
}

/// Adds a proxy alias: one name or every name below a domain, sent to a container.
struct AddAliasSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let containers: [ContainerSummary]
    @State private var pattern = ""
    @State private var container = ""
    @State private var portText = ""

    private var names: [String] {
        containers.filter { $0.name != "buildkit" }.map(\.name).sorted()
    }

    private var normalized: String { HostName.normalize(pattern) }
    private var patternIsValid: Bool { HostName.isValidPattern(normalized) }
    private var port: Int? { Int(portText.trimmingCharacters(in: .whitespaces)) }
    private var portIsValid: Bool { portText.trimmingCharacters(in: .whitespaces).isEmpty || (port.map { (1...65535).contains($0) } ?? false) }
    private var exists: Bool { DomainsStore.shared.aliases.contains { $0.pattern == normalized } }
    private var canSave: Bool { patternIsValid && portIsValid && !container.isEmpty && !exists }

    var body: some View {
        SheetScaffold("Add Alias", subtitle: "Send another name to a container through the proxy", icon: .tag) {
            DeckFormGroup {
                DeckFormRow("Name", note: "One name like api.localhost, or *.gateway.test for every name below gateway.test.") {
                    TextField("Name", text: $pattern, prompt: Text("api.localhost"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.body.monospaced())
                        .onSubmit(save)
                }
                DeckFormRow("Container") {
                    Picker("Container", selection: $container) {
                        Text("Choose").tag("")
                        ForEach(names, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                DeckFormRow("Port", note: "Leave empty to use the container's own route port.") {
                    TextField("Port", text: $portText, prompt: Text("Auto"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                }
            }
            if !normalized.isEmpty && !patternIsValid {
                ResourceWarningText("Use a full name like api.localhost or *.gateway.test.")
            } else if exists {
                ResourceWarningText("\(normalized) already exists.")
            } else if patternIsValid && HostName.needsResolver(normalized) {
                ResourceWarningText("Names outside .localhost need one admin step after you add them: Set Up DNS.")
            }
            if !portIsValid {
                ResourceWarningText("Use a port from 1 to 65535.")
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add Alias", action: save)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .onAppear {
            if container.isEmpty { container = names.first ?? "" }
        }
    }

    private func save() {
        guard canSave else { return }
        DomainsStore.shared.addAlias(ProxyAlias(pattern: normalized, container: container, port: port))
        state.showToast("Added \(normalized)", style: .success)
        dismiss()
    }
}

