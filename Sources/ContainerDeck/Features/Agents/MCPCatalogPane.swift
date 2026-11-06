import SwiftUI
import AppKit
import DeckCore

/// Curated MCP servers that run as containers, plus a custom server card.
struct MCPCatalogPane: View {
    let store: AgentsStore
    let onInstall: (MCPCatalogItem?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: Layout.cardSpacing, alignment: .top)]

    var body: some View {
        DeckPage {
            SectionHeader("MCP server catalog",
                          subtitle: "Each server runs in its own container. stdio servers start when an agent needs them, HTTP servers keep running.",
                          icon: .agents)
            LazyVGrid(columns: columns, spacing: Layout.cardSpacing) {
                customCard
                ForEach(MCPCatalog.items) { item in
                    card(item)
                }
            }
        }
    }

    private var customCard: some View {
        CatalogCard(
            icon: .wand, title: "Custom server", publisher: "Any image or command",
            summary: "Run any MCP server image, or a command on this Mac, and connect it to your agents.",
            detail: "image or command", transport: nil, installed: false,
            actionTitle: "Set Up", action: { onInstall(nil) }
        )
    }

    private func card(_ item: MCPCatalogItem) -> some View {
        let installed = store.installed.contains { $0.catalogID == item.id }
        return CatalogCard(
            icon: .agents, title: item.title, publisher: item.publisher, summary: item.summary,
            detail: item.image, transport: item.transport, installed: installed,
            actionTitle: installed ? "Add Another" : "Install", action: { onInstall(item) },
            homepage: URL(string: item.homepage)
        )
    }
}

private struct CatalogCard: View {
    let icon: DeckIconName
    let title: String
    let publisher: String
    let summary: String
    let detail: String
    let transport: MCPTransport?
    let installed: Bool
    let actionTitle: String
    let action: () -> Void
    var homepage: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(icon, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(publisher).font(.caption).foregroundStyle(DS.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if installed { Pill("Installed", tint: DS.running) }
            }
            Text(summary)
                .font(.callout)
                .foregroundStyle(DS.textSecondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let transport { Pill(transport.title, tint: transport.tint) }
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(DS.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let homepage {
                    Button {
                        NSWorkspace.shared.open(homepage)
                    } label: {
                        Image.deck(.openExternal, size: 12)
                    }
                    .buttonStyle(.borderless)
                    .help("Open the project page")
                }
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .modifier(PrimaryIf(active: !installed))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .deckCard()
    }
}

private struct PrimaryIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.deckPrimary() } else { content }
    }
}
