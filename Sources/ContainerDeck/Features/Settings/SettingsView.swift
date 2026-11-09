import SwiftUI
import AppKit
import DeckCore

struct SettingsView: View {
    @State private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label { Text("General") } icon: { Image.deck(.settings, size: 18) } }
                .tag("general")
            PlatformSettings()
                .tabItem { Label { Text("Platform") } icon: { Image.deck(.containers, size: 18) } }
                .tag("platform")
            RegistriesSettings()
                .tabItem { Label { Text("Registries") } icon: { Image.deck(.registry, size: 18) } }
                .tag("registries")
            AgentsSettings()
                .tabItem { Label { Text("Agents") } icon: { Image.deck(.agents, size: 18) } }
                .tag("agents")
            UpdatesSettings()
                .tabItem { Label { Text("Updates") } icon: { Image.deck(.download, size: 18) } }
                .tag("updates")
            ComponentsSettings()
                .tabItem { Label { Text("Components") } icon: { Image.deck(.components, size: 18) } }
                .tag("components")
            AboutSettings()
                .tabItem { Label { Text("About") } icon: { Image.deck(.info, size: 18) } }
                .tag("about")
        }
        .frame(width: 640, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: .deckDebugSettingsTab)) { note in
            if let value = note.object as? String { tab = value }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deckOpenSettingsTab)) { note in
            if let value = note.object as? String { tab = value }
        }
        .onAppear {
            if let pending = SettingsRouter.pendingTab {
                tab = pending
                SettingsRouter.pendingTab = nil
            }
        }
    }
}

private struct PlatformSettings: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.forceCLIBackend) private var forceCLI = false
    @State private var pathDraft = ""
    @State private var backend: BackendStatus?

    var body: some View {
        Form {
            Section {
                LabeledContent("Using") {
                    Text(state.report.cliPath ?? "Not found")
                        .font(.callout.monospaced())
                        .foregroundStyle(state.report.cliPath == nil ? DS.warning : DS.textPrimary)
                        .textSelection(.enabled)
                }
                LabeledContent("Version") {
                    if let version = state.report.cliVersion {
                        Pill("\(version)", tint: DS.accent)
                    } else {
                        Text("Unknown").foregroundStyle(DS.textSecondary)
                    }
                }
                LabeledContent("Service") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.report.serviceRunning ? DS.running : DS.stopped)
                            .frame(width: 7, height: 7)
                        Text(state.report.serviceRunning ? "Running" : "Stopped")
                    }
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(backend?.backend == .directAPI && backend?.forcedCLI != true ? DS.running : DS.stopped)
                            .frame(width: 7, height: 7)
                        Text(backend?.headline ?? "Not checked yet")
                    }
                    .fixedSize()
                } label: {
                    Text("Connection")
                    if let detail = backend?.detail {
                        Text(detail)
                    }
                }
                Toggle(isOn: $forceCLI) {
                    Text("Use the container command only")
                    Text("For troubleshooting.")
                }
                LabeledContent("Custom path") {
                    HStack(spacing: 8) {
                        TextField("Custom path", text: $pathDraft, prompt: Text("/usr/local/bin/container"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .font(.callout.monospaced())
                            .frame(maxWidth: 260)
                        Button("Reset") {
                            pathDraft = ""
                            state.setCustomCLIPath("")
                            Task { await state.refresh() }
                        }
                        .disabled(state.customCLIPath.isEmpty && pathDraft.isEmpty)
                        Button("Save") {
                            state.setCustomCLIPath(pathDraft)
                            Task { await state.refresh() }
                        }
                        .deckPrimary()
                        .disabled(pathDraft == state.customCLIPath)
                    }
                }
            } header: {
                Text("Container tool")
            } footer: {
                Text("Leave the custom path empty to find the tool on its own.")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Section {
                ForEach(state.report.checks) { check in
                    HStack(spacing: 10) {
                        StatusIcon(state: check.state)
                            .frame(width: 20)
                        Text(check.title)
                        Spacer()
                        Text(check.state.message)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.callout)
                }
                HStack(spacing: 8) {
                    if state.isChecking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        state.showSetup = true
                    } label: {
                        DeckLabel("Open Setup Guide", icon: .wand)
                    }
                    Button {
                        Task { await state.refresh() }
                    } label: {
                        DeckLabel("Check Again", icon: .refresh)
                    }
                    .disabled(state.isChecking)
                }
            } header: {
                Text("Setup checks")
            }
        }
        .formStyle(.grouped)
        .tint(DS.accent)
        .onAppear { pathDraft = state.customCLIPath }
        // The router reads the switch on every call, so it applies at once. Poll right away
        // so the list pace and the stats sampler follow, and keep the line current.
        .task(id: forceCLI) {
            BackgroundServices.shared.pollNow()
            while !Task.isCancelled {
                backend = await state.router?.status()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct AboutSettings: View {
    @State private var stats: RepoStats?
    @State private var statsNote: String?

    var body: some View {
        VStack(spacing: 18) {
            LogoTile(size: 84)
            Text(AppConfig.appName)
                .font(.system(size: 22, weight: .semibold))
            HStack(spacing: 8) {
                Pill("Version \(appVersion)")
                Pill(AppConfig.license, tint: DS.textSecondary)
            }

            statsRow

            Text("A native Mac app for Apple's container tool.\nNot made by, affiliated with, or endorsed by Apple.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)

            HStack(spacing: 10) {
                linkButton("GitHub", icon: .openExternal, url: AppConfig.websiteURL)
                linkButton("Releases", icon: .download, url: AppConfig.websiteURL + "/releases")
                linkButton("License", icon: .license, url: AppConfig.websiteURL + "/blob/main/" + AppConfig.licenseFile)
                linkButton("Website", icon: .website, url: AppConfig.siteURL)
            }
            .controlSize(.regular)

            Link(destination: URL(string: AppConfig.authorURL) ?? URL(fileURLWithPath: "/")) {
                Text("Made by \(AppConfig.author)")
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(AppConfig.authorURL)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(DS.accent)
        .task { await loadStats() }
    }

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 10) {
            statChip(.star, label: "Stars", value: stats?.stars)
            statChip(.fork, label: "Forks", value: stats?.forks)
            statChip(.download, label: "Downloads", value: stats?.downloads)
        }
        .fixedSize(horizontal: false, vertical: true)
        if let statsNote {
            Text(statsNote)
                .font(.caption)
                .foregroundStyle(DS.textTertiary)
        }
    }

    private func statChip(_ icon: DeckIconName, label: String, value: Int?) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                DeckIcon(icon, size: 13, color: DS.textSecondary)
                    .environment(\.deckIconMonochrome, true)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(DS.textSecondary)
            }
            Group {
                if let value {
                    Text(Format.compactCount(value))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                } else {
                    SkeletonBlock(width: 34, height: 14).shimmer(active: statsNote == nil)
                        .frame(height: 20)
                }
            }
        }
        .frame(width: 104)
        .padding(.vertical, 10)
        .deckCard(radius: 10)
        .accessibilityElement(children: .combine)
    }

    private func linkButton(_ title: String, icon: DeckIconName, url: String) -> some View {
        Button {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        } label: {
            DeckLabel(title, icon: icon)
        }
        .help(url)
    }

    private func loadStats() async {
        do {
            stats = try await RepoStatsClient().fetch()
            statsNote = nil
        } catch let error as RepoStatsError {
            stats = RepoStats(stars: 0, forks: 0, downloads: 0)
            statsNote = error == .notPublished ? "Numbers appear once the repository is public." : error.localizedDescription
        } catch {
            statsNote = "Could not reach GitHub."
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
