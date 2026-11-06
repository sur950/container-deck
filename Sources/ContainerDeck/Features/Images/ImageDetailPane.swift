import SwiftUI
import DeckCore

/// Details for one image: overview, layers and raw JSON.
struct ImageDetailPane: View {
    @Environment(AppState.self) private var state

    let image: ImageSummary
    let onAction: (ImageRowAction) -> Void

    @State private var detail: ImageDetail?
    @State private var detailError: String?
    @State private var isLoading = false
    @State private var tab: DetailTab = .overview

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview, layers, inspect
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: return "Overview"
            case .layers: return "Layers"
            case .inspect: return "Inspect"
            }
        }
    }

    init(image: ImageSummary, onAction: @escaping (ImageRowAction) -> Void) {
        self.image = image
        self.onAction = onAction
    }

    private var loadKey: String {
        "\(image.reference)#\(state.resourcesVersion)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.pad)
                .padding(.top, DS.pad)
                .padding(.bottom, 12)
            SegmentedFilter(selection: $tab, options: DetailTab.allCases, label: { $0.title })
                .padding(.horizontal, DS.pad)
                .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .overview: overview
                case .layers: layers
                case .inspect: inspect
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Not into the title bar: the toolbar spans the whole window above both panes.
        .background(DS.surface, ignoresSafeAreaEdges: [])
        .task(id: loadKey) { await load() }
        .onDeckDebugCommand { name, value in
            // Automation: "image-tab:overview", "image-tab:layers" or "image-tab:inspect".
            if name == "image-tab", let target = DetailTab(rawValue: value) { tab = target }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                IconBadge(.images, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(image.shortName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Pill(image.tag)
                    }
                    Text(image.reference)
                        .font(.caption.monospaced())
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(image.reference)
                }
                Spacer(minLength: 0)
            }
            // One row when it fits, otherwise the icon buttons move to a second row.
            // Labels never get cut off.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    mainButtons
                    Spacer(minLength: 8)
                    iconButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { mainButtons }
                    HStack(spacing: 8) { iconButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var mainButtons: some View {
        Button {
            onAction(.run)
        } label: {
            DeckLabel("Run", icon: .play)
        }
        .deckPrimary()
        .fixedSize()

        Button {
            onAction(.pullLatest)
        } label: {
            DeckLabel("Pull Latest", icon: .pull)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var iconButtons: some View {
        iconButton(.tag, help: "Tag") { onAction(.tag) }
        iconButton(.export, help: "Save to file") { onAction(.save) }
        iconButton(.copy, help: "Copy name") { onAction(.copyReference) }
        iconButton(.trash, help: "Delete", tint: DS.danger) { onAction(.delete) }
    }

    private func iconButton(_ icon: DeckIconName, help: String, tint: Color = DS.textSecondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DeckIcon(icon, size: 14, color: tint)
                .frame(width: 18, height: 16)
        }
        .help(help)
        .accessibilityLabel(help)
    }

    // MARK: - Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                if let detailError {
                    ResourceErrorText(detailError)
                }
                Card("Image", icon: .images) {
                    VStack(alignment: .leading, spacing: 0) {
                        KeyValueRow("Digest", value: shownDigest.isEmpty ? "None" : shownDigest, monospaced: true, copyable: !shownDigest.isEmpty)
                        KeyValueRow("Size", value: Format.bytes(summary.sizeBytes))
                        KeyValueRow("Platforms") {
                            Text(ImagesScreen.platformText(summary.platforms))
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(summary.platforms.joined(separator: ", "))
                        }
                        KeyValueRow("Created") {
                            Text(createdText.isEmpty ? "Unknown" : createdText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        KeyValueRow("Used by") {
                            if image.usedBy.isEmpty {
                                Text("Not used").foregroundStyle(DS.textTertiary)
                            } else {
                                Text(image.usedBy.joined(separator: ", "))
                                    .lineLimit(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Card("Config", icon: .inspect) {
                    if let config = detail?.config {
                        VStack(alignment: .leading, spacing: 0) {
                            configRow("Entrypoint", config.entrypoint.joined(separator: " "))
                            configRow("Command", config.cmd.joined(separator: " "))
                            configRow("Working dir", config.workingDir ?? "")
                            configRow("User", config.user ?? "", monospaced: false)
                            // Apple's tool does not report exposed ports, so only show them when present.
                            if !config.exposedPorts.isEmpty {
                                configRow("Ports", config.exposedPorts.joined(separator: ", "), monospaced: false)
                            }
                        }
                    } else if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading").foregroundStyle(DS.textSecondary)
                        }
                        .font(.callout)
                    } else {
                        Text("No config found.").font(.callout).foregroundStyle(DS.textSecondary)
                    }
                }
                if let config = detail?.config, !config.env.isEmpty {
                    Card("Environment", icon: .terminal) {
                        keyValueList(config.env.map { ($0.key, $0.value) })
                    }
                }
                if let config = detail?.config, !config.labels.isEmpty {
                    Card("Labels", icon: .tag) {
                        keyValueList(config.labels.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
                    }
                }
            }
            .padding(DS.pad)
        }
    }

    private func configRow(_ key: String, _ value: String, monospaced: Bool = true) -> some View {
        KeyValueRow(key) {
            if value.isEmpty {
                Text("None").foregroundStyle(DS.textTertiary)
            } else {
                Text(value)
                    .font(monospaced ? Font.callout.monospaced() : Font.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func keyValueList(_ pairs: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pairs.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 1) {
                    Text(pairs[index].0)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(DS.textPrimary)
                    Text(pairs[index].1.isEmpty ? "Empty" : pairs[index].1)
                        .font(.caption.monospaced())
                        .foregroundStyle(pairs[index].1.isEmpty ? DS.textTertiary : DS.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                if index < pairs.count - 1 {
                    Divider().opacity(0.6)
                }
            }
        }
    }

    private var summary: ImageSummary {
        detail?.summary ?? image
    }

    private var shownDigest: String {
        summary.digest.isEmpty ? image.digest : summary.digest
    }

    private var createdText: String {
        guard let date = summary.createdAt ?? image.createdAt else { return "" }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) (\(Format.relative(date)))"
    }

    // MARK: - Layers

    @ViewBuilder
    private var layers: some View {
        if let detail, !detail.layers.isEmpty {
            List {
                Section {
                    ForEach(detail.layers.indices, id: \.self) { index in
                        ImageLayerRow(number: index + 1, layer: detail.layers[index])
                    }
                } header: {
                    Text(layerHeader(detail.layers))
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        } else if isLoading {
            LoadingView("Loading layers")
        } else {
            EmptyState(icon: .layers, title: "No layer data", message: "This image has no layer details to show.")
        }
    }

    private func layerHeader(_ layers: [ImageLayer]) -> String {
        let count = layers.count == 1 ? "1 layer" : "\(layers.count) layers"
        let total = layers.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        return total > 0 ? "\(count), \(Format.bytes(total))" : count
    }

    // MARK: - Inspect

    @ViewBuilder
    private var inspect: some View {
        if let detail, !detail.rawJSON.isEmpty {
            ResourceLogView(lines: detail.rawJSON.components(separatedBy: "\n"))
                .padding(DS.pad)
        } else if isLoading {
            LoadingView("Loading", style: .detail)
        } else {
            EmptyState(icon: .inspect, title: "Nothing to show", message: "The image could not be inspected.")
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let client = state.client else { return }
        // Do not show the last image's config while the new one loads.
        if detail?.summary.reference != image.reference {
            detail = nil
            detailError = nil
        }
        isLoading = true
        do {
            let result = try await client.inspectImage(image.reference)
            if Task.isCancelled { return }
            detail = result
            detailError = nil
        } catch {
            if Task.isCancelled { return }
            detail = nil
            detailError = error.localizedDescription
        }
        isLoading = false
    }
}

private struct ImageLayerRow: View {
    let number: Int
    let layer: ImageLayer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DS.textTertiary)
                    .frame(width: 22, alignment: .leading)
                // `image inspect` has no per layer sizes, so hide a zero.
                if layer.sizeBytes > 0 {
                    Text(Format.bytes(layer.sizeBytes))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                Spacer()
                Text(String(layer.digest.prefix(19)))
                    .font(.caption2.monospaced())
                    .foregroundStyle(DS.textSecondary)
                    .help(layer.digest)
            }
            if let command = layer.createdBy, !command.isEmpty {
                Text(command)
                    .font(.caption.monospaced())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(command)
            }
        }
        .padding(.vertical, 3)
    }
}
