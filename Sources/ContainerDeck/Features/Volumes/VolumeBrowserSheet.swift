import SwiftUI
import DeckCore

/// Browse a volume's files. Starts a small helper container with the volume
/// mounted at /data, and stops it when the sheet closes.
struct VolumeBrowserSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let volume: VolumeSummary

    @State private var helperID: String?
    @State private var errorMessage: String?
    @State private var attempt = 0

    static let helperImage = "docker.io/library/alpine:latest"
    static let mountPath = "/data"

    var body: some View {
        VStack(spacing: 0) {
            // Same header as SheetScaffold. The body is a full size browser, so it does not scroll.
            HStack(spacing: 12) {
                IconBadge(.volumes, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files in \(volume.name)").font(.title3.weight(.semibold))
                    Text("Mounted at \(Self.mountPath) in a small helper container")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            Divider()
            Group {
                if let helperID {
                    FileBrowserView(containerID: helperID, rootPath: Self.mountPath)
                } else if let errorMessage {
                    EmptyState(
                        icon: .error,
                        title: "Could not open the volume",
                        message: errorMessage.contains("Stop it") ? errorMessage
                            : errorMessage + " If a running container uses this volume, stop it and try again.",
                        actionTitle: "Try Again"
                    ) {
                        attempt += 1
                    }
                } else {
                    LoadingView("Starting a small helper container")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.surface)
            Divider()
            HStack(spacing: 10) {
                if helperID == nil && errorMessage == nil {
                    Text("Uses the alpine image. It stops when you close this window.")
                        .font(.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 0)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(DS.surface)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
        .task(id: attempt) { await startHelper() }
        .onDisappear { stopHelper() }
    }

    static func helperName(for volume: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let cleaned = String(volume.lowercased().map { allowed.contains($0) ? $0 : "-" }.prefix(30))
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "deck-volume-\(cleaned)-\(suffix)"
    }

    private func startHelper() async {
        guard helperID == nil else { return }
        guard let client = state.client else {
            errorMessage = "Apple's container tool is not installed."
            return
        }
        errorMessage = nil
        let name = Self.helperName(for: volume.name)
        let options = RunOptions(
            image: Self.helperImage,
            name: name,
            command: ["sleep", "86400"],
            mounts: [MountSpec(kind: .volume, source: volume.name, destination: Self.mountPath)],
            labels: [ResourceUsage.helperLabel: "volume-browser", "deck.volume": volume.name],
            detach: true,
            autoRemove: true
        )
        do {
            let returned = try await client.runContainer(options).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = returned.isEmpty ? name : returned
            if Task.isCancelled {
                // The sheet closed while the helper was starting.
                Self.stop(id, client: client)
                return
            }
            helperID = id
        } catch {
            if !Task.isCancelled {
                errorMessage = Self.friendlyError(error.localizedDescription)
            }
        }
    }

    private func stopHelper() {
        guard let id = helperID, let client = state.client else { return }
        helperID = nil
        let appState = state
        Task {
            try? await client.stopContainer(id)
            // The helper is gone, so the volume list no longer shows it as a user.
            appState.resourcesChanged()
        }
    }

    /// A volume can only be attached to one running VM. The tool then fails with
    /// a raw Virtualization error, so say what it means.
    static func friendlyError(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("storage device attachment is invalid") || lower.contains("currently in use") {
            return "A running container is using this volume. Stop it and try again."
        }
        return message
    }

    /// Stops the helper. It removes itself because it runs with autoRemove.
    static func stop(_ id: String, client: ContainerClient) {
        Task.detached {
            try? await client.stopContainer(id)
        }
    }
}
