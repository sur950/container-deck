import SwiftUI
import AppKit
import DeckCore

extension PrefKey {
    /// Catalog tab section: "featured" or "browse".
    static let mcpCatalogSection = "mcpCatalogSection"
}

/// Source pill colors: crimson for the registry, grey for Docker (only one accent).
extension MCPRegistrySource {
    var tint: Color { self == .registry ? DS.accent : DS.stopped }
}

/// Browse: one page of results in a table, a footer with Previous and Next, and the details pane.
struct MCPBrowseView: View {
    let store: AgentsStore
    @Bindable var registry: MCPRegistryStore
    let onInstall: (MCPCatalogItem) -> Void

    var body: some View {
        content
            .task(id: registry.source.rawValue + "|" + registry.query) { await registry.searchAfterPause() }
    }

    @ViewBuilder
    private var content: some View {
        if !registry.hasLoaded {
            LoadingView("Searching MCP servers", style: .logo)
        } else if let error = registry.error, registry.results.isEmpty {
            EmptyState(icon: .error, title: "Could not search", message: error, actionTitle: "Try Again") {
                Task { await registry.reload() }
            }
        } else if registry.results.isEmpty {
            EmptyState(icon: .search, title: "No servers found",
                       message: registry.trimmedQuery.isEmpty ? "Nothing to show from \(registry.source.title) right now."
                                                              : "Nothing matches \"\(registry.trimmedQuery)\". Try a shorter name.")
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if registry.visible.isEmpty {
                        EmptyState(icon: .filter, title: "No servers match these filters",
                                   message: "This page has no server with that transport. Turn a filter off or go to the next page.")
                    } else {
                        table
                    }
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Group {
                    if let server = registry.visible.first(where: { $0.id == registry.selection }) ?? registry.visible.first {
                        MCPRegistryDetailPane(server: server, installed: store.installed, onInstall: onInstall)
                            .id(server.id)
                    } else {
                        EmptyState(icon: .agents, title: "Pick a server", message: "Its settings and links show here.")
                    }
                }
                .frame(width: MCPCatalogPane.detailWidth)
                .frame(maxHeight: .infinity)
                .background(DS.surface, ignoresSafeAreaEdges: [])
            }
        }
    }

    private var table: some View {
        Table(registry.visible, selection: $registry.selection) {
            TableColumn("Name") { server in
                HStack(spacing: 8) {
                    DeckIcon(server.source == .docker ? .containers : .agents, size: 14, color: DS.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.displayTitle).fontWeight(.medium).lineLimit(1)
                        Text(server.name).font(.caption.monospaced()).deckTertiaryText().lineLimit(1).truncationMode(.middle)
                    }
                    if store.installed.contains(where: { $0.catalogID == server.id }) { Pill("Installed", tint: DS.running) }
                    if !server.isInstallable { Pill("Not supported", tint: DS.warning) }
                }
                .help(server.description)
            }
            .width(min: 200, ideal: 240)
            TableColumn("Source") { server in
                Pill(server.source.title, tint: server.source.tint)
            }
            .width(min: 96, ideal: 100)
            TableColumn("Transport") { server in
                HStack(spacing: 4) {
                    ForEach(server.transports, id: \.self) { Pill($0.title, tint: $0.tint) }
                }
            }
            .width(min: 90, ideal: 100)
            TableColumn("Version") { server in
                Text(server.version ?? (server.pullCount.map { "\(Format.count($0)) pulls" } ?? "-"))
                    .monospacedDigit().deckSecondaryText().lineLimit(1)
            }
            .width(min: 60, ideal: 72)
            TableColumn("Updated") { server in
                Text(server.updated.map { Format.relative($0) } ?? "-").deckSecondaryText().lineLimit(1)
            }
            .width(min: 64, ideal: 80)
        }
        .scrollContentBackground(.hidden)
    }

    private var footer: some View {
        ListStatusBar(registry.rangeText + (registry.queryTooShort ? ". Type 3 letters to search" : "")) {
            if let error = registry.error {
                Text(error).font(.caption).foregroundStyle(DS.warning).lineLimit(1)
            }
            Button("Previous") { Task { await registry.goBack() } }
                .disabled(!registry.canGoBack)
                .controlSize(.small)
            Button("Next") { Task { await registry.goForward() } }
                .disabled(!registry.canGoForward)
                .controlSize(.small)
        }
    }
}

// MARK: - Details pane

/// Details of a browsed server: what it needs, links, and how it runs, with Install.
struct MCPRegistryDetailPane: View {
    let server: MCPRegistryServer
    let installed: [MCPInstalledServer]
    let onInstall: (MCPCatalogItem) -> Void

    private var primary: MCPCatalogItem? {
        server.installOptions.first.flatMap { MCPRegistryInstall.catalogItem(server, option: $0) }
    }

    var body: some View {
        MCPDetailFrame(installTitle: installTitle, onInstall: primary.map { item in { onInstall(item) } }) {
            MCPDetailHeader(icon: server.source == .docker ? .containers : .agents, title: server.displayTitle, subtitle: server.name)
            HStack(spacing: 6) {
                Pill(server.source.title, tint: server.source.tint)
                if let version = server.version { Pill("v\(version)", tint: DS.stopped) }
                if let pulls = server.pullCount { Pill("\(Format.count(pulls)) pulls", tint: DS.stopped) }
                if installed.contains(where: { $0.catalogID == server.id }) { Pill("Installed", tint: DS.running) }
            }
            if !server.description.isEmpty {
                Text(server.description).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if server.installOptions.isEmpty {
                ResourceWarningText("This server ships only as \(server.packages.map(\.registryType).joined(separator: ", ")) packages, which cannot run here yet.")
            }
            ForEach(Array(server.installOptions.enumerated()), id: \.element.id) { index, option in
                optionBlock(option, isFirst: index == 0)
            }
            if server.source == .docker {
                Text("Docker's catalog does not list the settings a server needs. Add any its page asks for in the install form.")
                    .font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let url = server.websiteURL.flatMap(URL.init(string:)) { MCPLinkButton(title: "Website", url: url) }
                if let url = server.repositoryURL.flatMap(URL.init(string:)) { MCPLinkButton(title: "Repository", url: url) }
                if server.source == .docker, let url = server.homepage.flatMap(URL.init(string:)) { MCPLinkButton(title: "Docker Hub", url: url) }
            }
        }
    }

    private var installTitle: String {
        if case .remote? = server.installOptions.first { return "Connect by URL" }
        return "Install"
    }

    private func optionBlock(_ option: MCPRegistryInstallOption, isFirst: Bool) -> some View {
        MCPDetailBlock(title: blockTitle(option)) {
            Text(runText(option)).font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(runNote(option)).font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            if !option.inputs.isEmpty {
                Text(option.title == "Remote" ? "Headers" : "Settings").font(.caption.weight(.semibold)).foregroundStyle(DS.textSecondary)
                    .padding(.top, 4)
                ForEach(option.inputs) { input in
                    MCPInputRow(name: input.name, detail: input.description, required: input.isRequired, secret: input.isSecret)
                }
            }
            if !isFirst, let item = MCPRegistryInstall.catalogItem(server, option: option) {
                Button(option.title == "Remote" ? "Connect by URL" : "Install This Way") { onInstall(item) }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
    }

    private func blockTitle(_ option: MCPRegistryInstallOption) -> String {
        switch option {
        case .package(let package): return "\(package.kind.title) package, \(package.transport.title)"
        case .remote(let remote): return "Remote server, \(remote.transport.title)"
        }
    }

    private func runText(_ option: MCPRegistryInstallOption) -> String {
        switch option {
        case .package(let package):
            guard let run = MCPRegistryInstall.run(package) else { return package.identifier }
            return ([run.image] + run.command).joined(separator: " ")
        case .remote(let remote):
            return remote.url
        }
    }

    private func runNote(_ option: MCPRegistryInstallOption) -> String {
        switch option {
        case .package(let package):
            switch package.kind {
            case .oci: return "Runs the image in a container."
            case .npm: return "Runs with npx in a Node.js container, kept apart from your Mac."
            case .pypi: return "Runs with uvx in a Python container, kept apart from your Mac."
            case .other: return "This package type cannot run here yet."
            }
        case .remote:
            return "Nothing runs here. Agents connect to this URL."
        }
    }
}

// MARK: - Shared detail parts

/// Scrolling details with an Install bar at the bottom.
struct MCPDetailFrame<Content: View>: View {
    let installTitle: String
    let onInstall: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button(installTitle) { onInstall?() }
                    .deckPrimary()
                    .disabled(onInstall == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

struct MCPDetailHeader: View {
    let icon: DeckIconName
    let title: String
    let subtitle: String
    var monospaced = true

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(icon, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(monospaced ? .caption.monospaced() : .callout).foregroundStyle(DS.textSecondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}

struct MCPDetailBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(DS.textSecondary)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .deckCard(radius: DS.smallRadius + 2)
        }
    }
}

struct MCPInputRow: View {
    let name: String
    let detail: String
    let required: Bool
    let secret: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(name).font(.callout.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                if required { Pill("Required", tint: DS.accent) }
                if secret { Pill("Secret", tint: DS.stopped) }
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MCPLinkButton: View {
    let title: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            DeckLabel(title, icon: .openExternal)
        }
        .deckLink()
        .help(url.absoluteString)
    }
}
