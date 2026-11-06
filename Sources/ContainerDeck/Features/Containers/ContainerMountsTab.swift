import SwiftUI
import AppKit
import DeckCore

/// Every mount of a container: bind folders with Show in Finder, volumes with a
/// file browser, tmpfs and block mounts with what they mean.
struct ContainerMountsTab: View {
    @Environment(AppState.self) private var state
    @AppStorage(PrefKey.showCommandHints) private var showHints = true

    let detail: ContainerDetail

    @State private var browse: MountBrowseTarget?
    @State private var browseVolume: VolumeSummary?

    init(detail: ContainerDetail) {
        self.detail = detail
    }

    private var summary: ContainerSummary { detail.summary }

    var body: some View {
        VStack(spacing: 0) {
            ContainerTabBar {
                Text(countText)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                Spacer(minLength: 8)
                if showHints, let client = state.client {
                    CommandHint(client.commandLine(["inspect", summary.id]))
                        .frame(maxWidth: 360)
                }
            }
            if detail.mounts.isEmpty {
                EmptyState(
                    icon: .volumes,
                    title: "No mounts",
                    message: "This container has no folders or volumes attached. Use Edit and Recreate to add one."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(detail.mounts.enumerated()), id: \.offset) { _, mount in
                            MountRow(
                                mount: mount,
                                isRunning: summary.isRunning,
                                browse: { open(mount) }
                            )
                        }
                    }
                    .padding(Layout.pagePadding)
                    .frame(maxWidth: Layout.maxContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .sheet(item: $browse) { target in
            MountBrowserSheet(target: target)
                .environment(state)
                .tint(DS.accent)
        }
        .sheet(item: $browseVolume) { volume in
            VolumeBrowserSheet(volume: volume)
                .environment(state)
                .tint(DS.accent)
        }
        .onDeckDebugCommand { name, value in
            // Automation only: mounts-browse:<destination> opens the browser for that mount.
            if name == "mounts-browse", let mount = detail.mounts.first(where: { $0.destination == value }) {
                open(mount)
            }
        }
    }

    private var countText: String {
        let count = detail.mounts.count
        return count == 1 ? "1 mount" : "\(count) mounts"
    }

    /// A running container is browsed in place. A stopped one's volume gets a helper.
    private func open(_ mount: MountInfo) {
        if summary.isRunning {
            browse = MountBrowseTarget(containerID: summary.id, containerName: summary.name, path: mount.destination, kind: mount.type)
        } else if mount.type == "volume" {
            browseVolume = VolumeSummary(name: mount.source)
        } else if let url = MountPaths.hostURL(for: mount) {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What the mount browser shows.
struct MountBrowseTarget: Identifiable, Hashable {
    var containerID: String
    var containerName: String
    var path: String
    var kind: String
    var id: String { containerID + path }
}

/// Paths on the Mac for mounts.
enum MountPaths {
    /// The folder on the Mac for a bind mount, when it is there.
    static func hostURL(for mount: MountInfo) -> URL? {
        guard mount.type == "bind", mount.source.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: mount.source)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The disk image that backs a named volume.
    static func volumeImage(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: MachineBootConfig.defaultAppRoot)
            .appendingPathComponent("volumes")
            .appendingPathComponent(name)
            .appendingPathComponent("volume.img")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// One mount: where it goes, where it comes from and what you can do with it.
private struct MountRow: View {
    @Environment(AppState.self) private var state
    /// AppKit menus keep the old colors after a Light or Dark switch. They rebuild with `.id(colorScheme)`.
    @Environment(\.colorScheme) private var colorScheme
    let mount: MountInfo
    let isRunning: Bool
    let browse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            IconBadge(icon, tint: tint, size: 34)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(mount.destination.isEmpty ? "Unknown path" : mount.destination)
                        .font(.body.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Pill(kindTitle, tint: DS.stopped)
                    if mount.readOnly { Pill("Read only", tint: DS.warning) }
                }
                Text(sourceText)
                    .font(.callout.monospaced())
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(mount.source)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(DS.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(14)
        .deckCard(radius: DS.smallRadius + 2)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch mount.type {
            case "bind":
                Button {
                    if let url = MountPaths.hostURL(for: mount) { MountPaths.showInFinder(url) }
                } label: {
                    DeckLabel("Show in Finder", icon: .folder)
                }
                .disabled(MountPaths.hostURL(for: mount) == nil)
                .help(MountPaths.hostURL(for: mount) == nil ? "The folder is not on this Mac anymore." : mount.source)
                if isRunning {
                    Button(action: browse) {
                        DeckLabel("Browse", icon: .files)
                    }
                    .help("Browse the folder as the container sees it")
                }
            case "volume":
                Button(action: browse) {
                    DeckLabel("Browse Files", icon: .files)
                }
                .help(isRunning ? "Browse the volume inside the container" : "Opens the volume in a small helper container")
                Menu {
                    Button {
                        if let url = MountPaths.volumeImage(mount.source) { MountPaths.showInFinder(url) }
                    } label: {
                        DeckLabel("Show Disk Image in Finder", icon: .disk)
                    }
                    .disabled(MountPaths.volumeImage(mount.source) == nil)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mount.source, forType: .string)
                    } label: {
                        DeckLabel("Copy Volume Name", icon: .copy)
                    }
                    Button {
                        state.selection = .volumes
                    } label: {
                        DeckLabel("Open Volumes", icon: .volumes)
                    }
                } label: {
                    DeckLabel("More", icon: .more)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .id(colorScheme)
            default:
                if isRunning {
                    Button(action: browse) {
                        DeckLabel("Browse", icon: .files)
                    }
                }
            }
        }
        .fixedSize()
    }

    private var icon: DeckIconName {
        switch mount.type {
        case "bind": return .folder
        case "volume": return .volumes
        case "tmpfs": return .memory
        default: return .disk
        }
    }

    private var tint: Color {
        mount.type == "bind" || mount.type == "volume" ? DS.accent : DS.stopped
    }

    private var kindTitle: String {
        switch mount.type {
        case "bind": return "Folder"
        case "volume": return "Volume"
        case "tmpfs": return "Memory"
        case "block": return "Block"
        default: return mount.type.capitalized
        }
    }

    private var sourceText: String {
        switch mount.type {
        case "bind":
            return ContainerText.tildePath(mount.source)
        case "volume":
            return mount.source.isEmpty ? "Anonymous volume" : "Volume \(mount.source)"
        case "tmpfs":
            return "In memory"
        default:
            return mount.source.isEmpty ? "No source" : ContainerText.tildePath(mount.source)
        }
    }

    private var explanation: String {
        switch mount.type {
        case "bind": return mount.readOnly ? "A folder on your Mac. The container can read it." : "A folder on your Mac, shared with the container."
        case "volume": return "Kept by the container platform. Survives when the container is deleted."
        case "tmpfs": return "Gone when the container stops."
        default: return "Attached disk."
        }
    }
}

/// Browses one mount path in a running container.
struct MountBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: MountBrowseTarget

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconBadge(target.kind == "volume" ? .volumes : .folder, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.path).font(.title3.weight(.semibold).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("In \(target.containerName)")
                        .font(.callout)
                        .foregroundStyle(DS.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            Divider()
            FileBrowserView(containerID: target.containerID, rootPath: target.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.surface)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(DS.surface)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 620)
    }
}

extension ContainerText {
    /// "/Users/me/src" becomes "~/src".
    static func tildePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
