import SwiftUI
import DeckCore

/// Copies a local image into the cluster's nodes, so pods can use it without a registry.
struct KubeLoadImageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let cluster: KubeCluster

    @State private var images: [ImageSummary] = []
    @State private var loaded = false
    @State private var reference = ""
    @State private var search = ""
    @State private var node = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        SheetScaffold(
            "Load Image",
            subtitle: "Copy an image from this Mac into \(cluster.name). No registry needed.",
            icon: .upload,
            width: 580
        ) {
            DeckFormGroup("Image") {
                DeckFormRow("Image") {
                    TextField("Image", text: $reference, prompt: Text("demo-api:latest"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Search", text: $search, prompt: Text("Search local images"))
                        .textFieldStyle(.roundedBorder)
                    imageList
                }
            }
            if cluster.nodes.count > 1 {
                DeckFormGroup("Nodes") {
                    DeckFormRow("Load into") {
                        Picker("Load into", selection: $node) {
                            Text("All nodes").tag("")
                            ForEach(cluster.nodes) { item in
                                Text(item.name).tag(item.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .leading)
                        .popUpAppearanceRefresh()
                    }
                }
            }
            DeckFormNote("In your pod spec use this exact image name and set imagePullPolicy to Never or IfNotPresent, so Kubernetes does not try to pull it.")
            if manualLoad {
                DeckFormNote("This container release has no load command, so the app saves the image, copies it into each node and imports it there.")
            }
            if let failure {
                ErrorNote(message: failure)
            }
            if manualLoad {
                // container 1.7 has no load-image. The app saves the image, copies it into each node and imports it.
                ResourceCommandHint(ContainerClient.clusterImageSaveArguments(image: shownReference, platform: nil, archive: "/tmp/image.tar"))
            } else {
                ResourceCommandHint(state.client?.loadImageArguments(cluster: cluster.name, image: shownReference, nodes: node.isEmpty ? [] : [node]) ?? [])
            }
        } footer: {
            if working {
                ProgressView().controlSize(.small)
                Text("Copying the image into the nodes.")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
            }
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
            Button("Load") { load() }
                .deckPrimary()
                .keyboardShortcut(.defaultAction)
                .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty || working)
        }
        .frame(height: 600)
        .task {
            guard let client = state.client else { return }
            images = ((try? await client.listImages()) ?? [])
                .filter { !$0.reference.contains("kindest/node") && !$0.reference.hasPrefix("sha256:") }
                .sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
            loaded = true
        }
    }

    private var shownReference: String { reference.isEmpty ? "<image>" : reference }

    /// container 1.7 removed `cluster load-image` (`ContainerPlatformFeatures.clusterLoadImage`).
    private var manualLoad: Bool {
        !ContainerPlatformFeatures(version: state.client?.platformVersion).clusterLoadImage
    }

    private var filtered: [ImageSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return images }
        return images.filter { $0.reference.localizedCaseInsensitiveContains(query) }
    }

    private var imageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(filtered, id: \.reference) { image in
                    KubeImageRow(reference: image.reference, size: image.sizeBytes, selected: image.reference == reference) {
                        reference = image.reference
                    }
                }
            }
        }
        .frame(height: 200)
        .background(DS.surfaceSunken.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.smallRadius, style: .continuous))
        .overlay {
            if !loaded {
                LoadingView("Loading images")
            } else if filtered.isEmpty {
                Text(images.isEmpty ? "No local images. Pull or build one first." : "No match")
                    .font(.callout)
                    .foregroundStyle(DS.textTertiary)
            }
        }
    }

    private func load() {
        guard let client = state.client else { return }
        let image = reference.trimmingCharacters(in: .whitespaces)
        working = true
        failure = nil
        Task {
            defer { working = false }
            do {
                try await client.loadImage(intoCluster: cluster.name, image: image, nodes: node.isEmpty ? [] : [node])
                state.showToast("Loaded \(image) into \(cluster.name).", style: .success)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct KubeImageRow: View {
    let reference: String
    let size: UInt64?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                DeckIcon(.images, size: 13, color: selected ? DS.accent : DS.textSecondary)
                Text(reference)
                    .font(.callout.monospaced())
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let size {
                    Text(Format.bytes(size))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DS.textSecondary)
                }
                if selected {
                    DeckIcon(.success, size: 13, color: DS.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? DS.accentSoft : (hovering ? DS.hover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
