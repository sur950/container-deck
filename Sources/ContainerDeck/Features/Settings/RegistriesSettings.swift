import SwiftUI
import DeckCore

/// Registry sign in and sign out, plus import from Docker credential helpers.
struct RegistriesSettings: View {
    @Environment(AppState.self) private var state

    @State private var registries: [RegistryLogin] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showSignIn = false
    @State private var pendingSignOut: String?
    @State private var helperSources: [DockerCredentialSource] = []
    @State private var importingID: String?

    var body: some View {
        Form {
            Section {
                if state.client == nil {
                    Text("Install Apple's container tool to sign in to registries.")
                        .foregroundStyle(DS.textSecondary)
                } else if registries.isEmpty && !isLoading {
                    Text("You are not signed in to any registry. Public images work without signing in.")
                        .foregroundStyle(DS.textSecondary)
                }
                ForEach(registries) { login in
                    HStack(spacing: 8) {
                        DeckIcon(.registry, size: 14, color: DS.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(login.displayHost)
                            if let username = login.username {
                                Text(username)
                                    .font(.caption)
                                    .foregroundStyle(DS.textSecondary)
                            }
                        }
                        .help(login.server)
                        Spacer()
                        Button("Sign Out") { pendingSignOut = login.server }
                    }
                }
                if let loadError {
                    ResourceErrorText(loadError)
                }
                HStack(spacing: 8) {
                    Spacer()
                    RefreshButton(help: "Refresh logins", isBusy: isLoading) {
                        await load()
                    }
                    Button {
                        showSignIn = true
                    } label: {
                        DeckLabel("Sign In…", icon: .add)
                    }
                    .deckPrimary()
                    .disabled(state.client == nil)
                }
            } header: {
                Text("Registries")
            } footer: {
                Text("Logins are kept in your Mac keychain by the container tool.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }

            Section {
                if helperSources.isEmpty {
                    Text("No credential helpers found in \(Self.configPathForDisplay).")
                        .foregroundStyle(DS.textSecondary)
                }
                ForEach(helperSources) { source in
                    HStack(spacing: 8) {
                        DeckIcon(.lock, size: 13, color: DS.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.server)
                            Text("docker-credential-\(source.helper)")
                                .font(.caption.monospaced())
                                .foregroundStyle(DS.textSecondary)
                        }
                        Spacer()
                        if registries.contains(where: { $0.matches(source.server) }) {
                            Pill("Signed in", tint: DS.running)
                        }
                        if importingID == source.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Import from \(source.helper)") {
                                importLogin(source)
                            }
                            .disabled(importingID != nil || state.client == nil)
                        }
                    }
                }
            } header: {
                Text("Docker credential helpers")
            } footer: {
                Text("Copies a login that Docker already has, so you do not type it again.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .task(id: state.resourcesVersion) { await load() }
        .sheet(isPresented: $showSignIn) {
            RegistrySignInSheet {
                Task { await load() }
            }
            .environment(state)
        }
        .alert("Sign out of \(DockerConfigFile.registryHost(from: pendingSignOut ?? ""))?", isPresented: signOutShown, presenting: pendingSignOut) { server in
            Button("Sign Out", role: .destructive) { signOut(server) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Private images from this registry will no longer pull.")
        }
    }

    static var configPathForDisplay: String {
        let path = DockerConfigFile.defaultPath()
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + String(path.dropFirst(home.count)) : path
    }

    private var signOutShown: Binding<Bool> {
        Binding(
            get: { pendingSignOut != nil },
            set: { shown in if !shown { pendingSignOut = nil } }
        )
    }

    private func load() async {
        helperSources = DockerConfigFile.load()?.sources ?? []
        guard let client = state.client else { return }
        isLoading = true
        do {
            registries = try await client.registryLogins().sorted { $0.displayHost < $1.displayHost }
            loadError = nil
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    private func signOut(_ server: String) {
        guard let client = state.client else { return }
        Task {
            do {
                try await client.registryLogout(server: server)
                state.showToast("Signed out of \(DockerConfigFile.registryHost(from: server))", style: .success)
                await load()
            } catch {
                state.showError(error)
            }
        }
    }

    private func importLogin(_ source: DockerCredentialSource) {
        guard let client = state.client, importingID == nil else { return }
        importingID = source.id
        Task {
            do {
                let helper = DockerCredentialHelper(name: source.helper)
                let credential = try await helper.get(server: source.configKey)
                try await client.registryLogin(server: source.server, username: credential.username, password: credential.secret)
                state.showToast("Signed in to \(source.server) as \(credential.username)", style: .success)
                await load()
            } catch {
                state.showError(error)
            }
            importingID = nil
        }
    }
}

/// Registries people sign in to most.
enum RegistrySignInPreset: String, CaseIterable, Identifiable {
    case dockerHub, github, quay, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dockerHub: return "Docker Hub"
        case .github: return "GitHub (ghcr.io)"
        case .quay: return "Quay (quay.io)"
        case .custom: return "Other registry"
        }
    }

    var server: String {
        switch self {
        case .dockerHub: return "docker.io"
        case .github: return "ghcr.io"
        case .quay: return "quay.io"
        case .custom: return ""
        }
    }

    var note: String {
        switch self {
        case .dockerHub:
            return "Use a personal access token from Docker Hub, Account settings, Personal access tokens. Your password does not work when two step sign in is on."
        case .github:
            return "Use a GitHub personal access token with the read:packages scope. Add write:packages to push."
        case .quay:
            return "Use your Quay username and password, or a robot account and its token."
        case .custom:
            return "Enter the registry host, like registry.example.com or localhost:5000."
        }
    }
}

/// Sign in to a registry with a username and a password or token.
struct RegistrySignInSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let onSignedIn: () -> Void

    @State private var preset: RegistrySignInPreset = .dockerHub
    @State private var customServer = ""
    @State private var username = ""
    @State private var password = ""
    @State private var plainHTTP = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(onSignedIn: @escaping () -> Void) {
        self.onSignedIn = onSignedIn
    }

    private var server: String {
        let raw = preset == .custom ? customServer : preset.server
        return DockerConfigFile.registryHost(from: raw)
    }

    private var scheme: String? {
        preset == .custom && plainHTTP ? "http" : nil
    }

    private var hintArguments: [String] {
        let user = username.isEmpty ? "<user>" : username
        let host = server.isEmpty ? "<server>" : server
        if let client = state.client {
            return client.registryLoginArguments(server: host, username: user, scheme: scheme)
        }
        return ["registry", "login", "--username", user, "--password-stdin", host]
    }

    private var canSignIn: Bool {
        !server.isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isWorking
    }

    var body: some View {
        SheetScaffold("Sign In to a Registry", subtitle: "Pull private images and push your own.", icon: .registry, width: 520) {
            DeckFormGroup {
                DeckFormRow("Registry") {
                    Picker("Registry", selection: $preset) {
                        ForEach(RegistrySignInPreset.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if preset == .custom {
                    DeckFormRow("Server") {
                        TextField("Server", text: $customServer, prompt: Text("registry.example.com"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                        Toggle("Use HTTP without TLS", isOn: $plainHTTP)
                            .toggleStyle(.checkbox)
                    }
                }
                DeckFormRow("Username") {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                DeckFormRow("Password") {
                    SecureField("Password or token", text: $password, prompt: Text("Password or token"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    DeckFormNote(preset.note)
                }
            }
            ResourceCommandHint(hintArguments)
            if let errorMessage {
                ResourceErrorText(errorMessage)
            }
        } footer: {
            if isWorking {
                ProgressView().controlSize(.small)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Sign In", action: signIn)
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSignIn)
        }
        .frame(height: 470)
    }

    private func signIn() {
        guard let client = state.client, canSignIn else { return }
        let host = server
        let user = username.trimmingCharacters(in: .whitespaces)
        let secret = password
        let loginScheme = scheme
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await client.registryLogin(server: host, username: user, password: secret, scheme: loginScheme)
                password = ""
                state.showToast("Signed in to \(host)", style: .success)
                onSignedIn()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
