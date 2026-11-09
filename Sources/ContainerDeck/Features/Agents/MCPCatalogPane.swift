import SwiftUI
import AppKit
import DeckCore

/// Catalog tab: Featured (the most pulled servers in Docker's MCP catalog that work for most people,
/// see `MCPCatalog`) or Browse (the MCP Registry and Docker's MCP catalog), each a list with a
/// details pane on the right.
struct MCPCatalogPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case featured, browse
        var id: String { rawValue }
        var title: String { self == .featured ? "Featured" : "Browse" }
    }

    let store: AgentsStore
    @Bindable var registry: MCPRegistryStore
    let onInstall: (MCPCatalogItem?) -> Void
    @AppStorage(PrefKey.mcpCatalogSection) private var sectionRaw = Section.featured.rawValue
    @State private var featuredSelection = MCPCatalog.featured(.noAccount).first?.id ?? MCPCatalogPane.customID

    static let customID = "custom"
    static let detailWidth: CGFloat = 340

    private var section: Section { Section(rawValue: sectionRaw) ?? .featured }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            switch section {
            case .featured: featured
            case .browse: MCPBrowseView(store: store, registry: registry, onInstall: { onInstall($0) })
            }
        }
        .onDeckDebugCommand { name, value in
            switch name {
            case "mcp-section": sectionRaw = Section(rawValue: value)?.rawValue ?? sectionRaw
            case "mcp-browse":
                sectionRaw = Section.browse.rawValue
                registry.query = value
            case "mcp-source": registry.source = MCPSourceFilter(rawValue: value) ?? registry.source
            case "mcp-transport":
                if let filter = MCPTransportFilter(rawValue: value) {
                    if registry.transports.contains(filter) { registry.transports.remove(filter) } else { registry.transports.insert(filter) }
                }
            case "mcp-open": registry.selection = registry.results.first { $0.name == value }?.id ?? registry.selection
            case "mcp-featured": featuredSelection = value
            case "mcp-next": Task { await registry.goForward() }
            case "mcp-prev": Task { await registry.goBack() }
            default: break
            }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            SegmentedFilter(selection: Binding(get: { section }, set: { sectionRaw = $0.rawValue }), options: Section.allCases,
                            label: { $0.title }) { option in
                option == .featured ? MCPCatalog.items.count : nil
            }
            if section == .browse {
                HStack(spacing: 6) {
                    DeckIcon(.search, size: 13, color: DS.textSecondary)
                    TextField("Search MCP servers", text: $registry.query)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await registry.reload() } }
                    if registry.isLoading { ProgressView().controlSize(.small) }
                    if !registry.query.isEmpty {
                        Button {
                            registry.query = ""
                        } label: {
                            DeckIcon(.close, size: 10, color: DS.textTertiary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 300)
                .background(DS.surfaceSunken, in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
                HStack(spacing: 6) {
                    ForEach(MCPSourceFilter.allCases) { option in
                        MCPFilterChip(title: option.title, selected: registry.source == option) { registry.source = option }
                    }
                }
                Divider().frame(height: 18)
                HStack(spacing: 6) {
                    ForEach(MCPTransportFilter.allCases) { option in
                        MCPFilterChip(title: option.title, selected: registry.transports.contains(option)) {
                            if registry.transports.contains(option) { registry.transports.remove(option) } else { registry.transports.insert(option) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.pagePadding)
        .padding(.vertical, 10)
    }

    // MARK: Featured

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top)]

    private var featured: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("The most pulled servers in Docker's MCP catalog that work for most people.")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(MCPCatalogGroup.allCases) { group in
                        let items = MCPCatalog.featured(group, live: registry.featuredPulls)
                        featuredGroup(group.title, note: group.note, count: items.count) {
                            ForEach(items) { item in
                                tile(id: item.id, icon: .agents, title: item.title, detail: item.publisher, transport: item.transport,
                                     pulls: item.pulls(registry.featuredPulls),
                                     installed: store.installed.contains { $0.catalogID == item.id })
                            }
                        }
                    }
                    featuredGroup("Your own", note: "Any image or command.", count: nil) {
                        tile(id: Self.customID, icon: .wand, title: "Custom server", detail: "Any image or command", transport: nil,
                             pulls: nil, installed: false)
                    }
                }
                .padding(Layout.pagePadding - 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.surface)
            Divider()
            Group {
                if let item = MCPCatalog.items.first(where: { $0.id == featuredSelection }) {
                    MCPFeaturedDetail(item: item, pulls: item.pulls(registry.featuredPulls),
                                      installed: store.installed.contains { $0.catalogID == item.id }) { onInstall(item) }
                } else {
                    MCPCustomDetail { onInstall(nil) }
                }
            }
            .frame(width: Self.detailWidth)
            .frame(maxHeight: .infinity)
            .background(DS.surface, ignoresSafeAreaEdges: [])
        }
        .task { await registry.loadFeaturedPulls() }
    }

    private func featuredGroup<Tiles: View>(_ title: String, note: String, count: Int?, @ViewBuilder tiles: () -> Tiles) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(DS.textPrimary)
                if let count { Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(DS.textTertiary) }
                Text(note).font(.callout).foregroundStyle(DS.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            LazyVGrid(columns: columns, spacing: 12) { tiles() }
        }
    }

    private func tile(id: String, icon: DeckIconName, title: String, detail: String, transport: MCPTransport?, pulls: Int?,
                      installed: Bool) -> some View {
        let selected = featuredSelection == id
        return Button {
            featuredSelection = id
        } label: {
            HStack(spacing: 10) {
                IconBadge(icon, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).fontWeight(.semibold).foregroundStyle(DS.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        if let pulls {
                            HStack(spacing: 3) {
                                DeckIcon(.pull, size: 10, color: DS.textTertiary)
                                Text(CountFormat.compact(pulls)).font(.caption.monospacedDigit()).foregroundStyle(DS.textSecondary)
                            }
                            .help("\(pulls.formatted()) pulls on Docker Hub")
                        }
                    }
                    HStack(spacing: 6) {
                        if let transport { Pill(transport.title, tint: transport.tint) }
                        if installed { Pill("Installed", tint: DS.running) }
                        Text(detail).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deckCard()
            .overlay(RoundedRectangle(cornerRadius: DS.radius).strokeBorder(selected ? DS.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension MCPCatalogGroup {
    /// Short line next to the group title.
    var note: String {
        switch self {
        case .noAccount: return "Run as they are."
        case .account: return "Need a token or sign in from that service."
        }
    }
}

/// A small toggle chip for filters.
struct MCPFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.accent : DS.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? DS.accentSoft : DS.surfaceSunken))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Details of a featured server.
private struct MCPFeaturedDetail: View {
    let item: MCPCatalogItem
    let pulls: Int
    let installed: Bool
    let onInstall: () -> Void

    var body: some View {
        MCPDetailFrame(installTitle: installed ? "Add Another" : "Install", onInstall: onInstall) {
            MCPDetailHeader(icon: .agents, title: item.title, subtitle: item.publisher, monospaced: false)
            HStack(spacing: 6) {
                Pill(item.transport.title, tint: item.transport.tint)
                Pill("\(CountFormat.compact(pulls)) pulls", tint: DS.stopped)
                if installed { Pill("Installed", tint: DS.running) }
            }
            Text(item.summary).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            MCPDetailBlock(title: "Runs") {
                Text(([item.image] + item.command).joined(separator: " "))
                    .font(.callout.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(item.transport == .stdio ? "In a container the agent starts when it needs it." : "In a container that keeps running.")
                    .font(.caption).foregroundStyle(DS.textSecondary)
            }
            MCPDetailBlock(title: "Settings") {
                if item.fields.isEmpty && item.mount == nil && item.volume == nil {
                    Text("None needed").foregroundStyle(DS.textSecondary)
                }
                ForEach(item.fields) { field in
                    MCPInputRow(name: field.label, detail: field.key, required: field.required, secret: field.secret)
                }
                if let mount = item.mount {
                    MCPInputRow(name: mount.label, detail: "\(mount.isFile ? "File" : "Folder") mounted at \(mount.containerPath)",
                                required: !mount.optional, secret: false)
                }
                if let volume = item.volume {
                    MCPInputRow(name: "Saved data", detail: "Kept in a volume at \(volume.containerPath)", required: false, secret: false)
                }
                ForEach(item.env) { env in
                    MCPInputRow(name: env.key, detail: "Set to \(env.value) for you", required: false, secret: false)
                }
            }
            Text(popularityNote).font(.caption).foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                if let url = URL(string: item.homepage), !item.homepage.isEmpty {
                    MCPLinkButton(title: "Project page", url: url)
                }
                if let url = URL(string: item.configSource), !item.configSource.isEmpty {
                    MCPLinkButton(title: "Docker catalog entry", url: url)
                }
            }
        }
    }

    /// Where the count comes from. GitHub runs its own image but ranks by mcp/github.
    private var popularityNote: String {
        let repository = item.pullRepository ?? item.image
        let count = pulls.formatted()
        if repository != item.image { return "\(count) pulls of \(repository) on Docker Hub, the count used to rank it." }
        return "\(count) pulls on Docker Hub."
    }
}

private struct MCPCustomDetail: View {
    let onSetUp: () -> Void

    var body: some View {
        MCPDetailFrame(installTitle: "Set Up", onInstall: onSetUp) {
            MCPDetailHeader(icon: .wand, title: "Custom server", subtitle: "Any image or command", monospaced: false)
            Text("Run any MCP server image in a container, or a command on this Mac, and connect it to your agents.")
                .foregroundStyle(DS.textSecondary).fixedSize(horizontal: false, vertical: true)
            MCPDetailBlock(title: "Find more") {
                Text("Browse searches the MCP Registry and Docker's MCP catalog.").font(.callout).foregroundStyle(DS.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
