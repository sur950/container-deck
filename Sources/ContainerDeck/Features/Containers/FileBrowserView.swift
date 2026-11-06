import SwiftUI
import AppKit
import DeckCore

/// Browse, download, upload and delete files inside a running container.
/// The Volumes screen reuses it with a `rootPath`.
struct FileBrowserView: View {
    @Environment(AppState.self) private var state

    let containerID: String
    var rootPath: String

    @State private var path: String
    @State private var entries: [FileEntry] = []
    @State private var selection = Set<String>()
    @State private var sortOrder: [KeyPathComparator<BrowserFileRow>] = [KeyPathComparator(\BrowserFileRow.name)]
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var busyText: String?
    @State private var pendingDelete: [FileEntry]?
    @State private var reloadToken = 0
    @State private var isDropTarget = false
    /// Last folder that opened, to go back to when a new one fails.
    @State private var lastGoodPath: String?

    init(containerID: String, rootPath: String = "/") {
        self.containerID = containerID
        self.rootPath = rootPath
        _path = State(initialValue: rootPath.isEmpty ? "/" : rootPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            table
                .overlay { statusOverlay }
                .overlay {
                    if isDropTarget {
                        RoundedRectangle(cornerRadius: DS.smallRadius)
                            .stroke(DS.accent, lineWidth: 2)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL)
                    guard !files.isEmpty else { return false }
                    Task { await upload(files) }
                    return true
                } isTargeted: { targeted in
                    isDropTarget = targeted
                }
            ListStatusBar(statusText) {
                if let busyText {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                        Text(busyText)
                            .font(.caption)
                            .foregroundStyle(DS.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Drop files on the list to upload")
                        .font(.caption)
                        .foregroundStyle(DS.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .task(id: "\(path)#\(reloadToken)") {
            await load()
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete ?? []
                pendingDelete = nil
                Task { await delete(items) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Files are removed from the container. This cannot be undone.")
        }
    }

    // MARK: Toolbar

    private var actionBar: some View {
        ContainerTabBar {
            Button {
                goUp()
            } label: {
                Label {
                    Text("Up")
                } icon: {
                    // The chevron points right in the icon set. Turned in its own
                    // square frame it points up and stays centered.
                    DeckIcon(.chevronRight, size: 12)
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(-90))
                }
                .labelStyle(.titleAndIcon)
            }
            .help("Up one folder")
            .disabled(isAtRoot)
            .keyboardShortcut(.upArrow, modifiers: .command)

            breadcrumb
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                reloadToken += 1
            } label: {
                DeckIcon(.refresh, size: 13)
                    .frame(width: 18, height: 16)
            }
            .help("Reload this folder")

            Divider().frame(height: 18)

            Button {
                chooseUpload()
            } label: {
                DeckLabel("Upload", icon: .upload)
            }
            .help("Copy files from your Mac into this folder")

            Button {
                download(selectedEntries)
            } label: {
                DeckLabel("Download", icon: .download)
            }
            .disabled(selectedEntries.isEmpty)
            .help("Save the selected items to your Mac")

            Button(role: .destructive) {
                pendingDelete = selectedEntries
            } label: {
                DeckLabel("Delete", icon: .trash)
            }
            .disabled(selectedEntries.isEmpty)
            .help("Delete the selected items")
        }
        .labelStyle(.titleAndIcon)
        .disabled(busyText != nil)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        DeckIcon(.chevronRight, size: 9, color: DS.textTertiary)
                    }
                    let isLast = index == crumbs.count - 1
                    Button {
                        path = crumb.path
                    } label: {
                        HStack(spacing: 5) {
                            if index == 0 {
                                DeckIcon(.folder, size: 12, color: isLast ? DS.accent : DS.textSecondary)
                            }
                            Text(crumb.title)
                                .fontWeight(isLast ? .semibold : .regular)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLast ? DS.textPrimary : DS.textSecondary)
                    .disabled(isLast)
                }
            }
            .font(.callout.monospaced())
        }
    }

    private var statusText: String {
        let folders = entries.filter(\.isDirectory).count
        let files = entries.count - folders
        let base = "\(folders) \(folders == 1 ? "folder" : "folders"), \(files) \(files == 1 ? "file" : "files")"
        return selection.isEmpty ? base : "\(selection.count) selected, " + base
    }

    private struct Crumb {
        let title: String
        let path: String
    }

    private var crumbs: [Crumb] {
        let rootTitle = rootPath == "/" ? "/" : (rootPath.split(separator: "/").last.map(String.init) ?? rootPath)
        var list = [Crumb(title: rootTitle, path: rootPath)]
        guard path != rootPath, path.hasPrefix(rootPath) else {
            if path != rootPath { list.append(Crumb(title: path, path: path)) }
            return list
        }
        var current = rootPath
        for part in path.dropFirst(rootPath.count).split(separator: "/") {
            current = ContainerText.joinPath(current, String(part))
            list.append(Crumb(title: String(part), path: current))
        }
        return list
    }

    private var isAtRoot: Bool {
        normalized(path) == normalized(rootPath)
    }

    private func normalized(_ value: String) -> String {
        var text = value
        while text.count > 1 && text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func goUp() {
        guard !isAtRoot else { return }
        let parent = ContainerText.parentPath(path)
        path = parent.count < normalized(rootPath).count ? rootPath : parent
    }

    // MARK: Table

    private var rows: [BrowserFileRow] {
        let sorted = entries.map(BrowserFileRow.init).sorted(using: sortOrder)
        return sorted.filter(\.entry.isDirectory) + sorted.filter { !$0.entry.isDirectory }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \BrowserFileRow.name) { row in
                HStack(spacing: 7) {
                    DeckIcon(row.entry.isDirectory ? .folder : .file, size: 14, color: row.entry.isDirectory ? DS.accent : DS.textSecondary)
                    Text(row.name).lineLimit(1)
                    if row.entry.isSymlink {
                        DeckIcon(.link, size: 11, color: DS.textTertiary)
                            .help("Link")
                    }
                }
            }
            .width(min: 180, ideal: 280)

            TableColumn("Size", value: \BrowserFileRow.size) { row in
                Text(row.entry.isDirectory ? "-" : Format.bytes(row.size))
                    .monospacedDigit()
                    .foregroundStyle(DS.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \BrowserFileRow.modified) { row in
                Text(row.entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-")
                    .foregroundStyle(DS.textSecondary)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Permissions", value: \BrowserFileRow.permissions) { row in
                Text(row.permissions.isEmpty ? "-" : row.permissions)
                    .font(.callout.monospaced())
                    .foregroundStyle(DS.textSecondary)
            }
            .width(min: 90, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { ids in
            fileMenu(ids)
        } primaryAction: { ids in
            guard ids.count == 1, let id = ids.first, let item = findEntry(id), item.isDirectory || item.isSymlink else { return }
            path = item.path
        }
    }

    @ViewBuilder
    private func fileMenu(_ ids: Set<String>) -> some View {
        let items = entries.filter { ids.contains($0.path) }
        if items.count == 1, let item = items.first, item.isDirectory || item.isSymlink {
            Button {
                path = item.path
            } label: {
                DeckLabel("Open", icon: .folder)
            }
        }
        if !items.isEmpty {
            Button {
                download(items)
            } label: {
                DeckLabel("Download…", icon: .download)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            } label: {
                DeckLabel("Copy Path", icon: .copy)
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = items
            } label: {
                DeckLabel("Delete…", icon: .trash)
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let errorText, entries.isEmpty {
            EmptyState(icon: .error, title: "Could not open this folder", message: errorText, actionTitle: "Try Again") {
                reloadToken += 1
            }
        } else if isLoading && entries.isEmpty {
            LoadingView("Reading folder")
                .background(DS.surface)
        } else if !isLoading && entries.isEmpty {
            EmptyState(icon: .folder, title: "Empty folder", message: "Drop files here to upload them.")
        }
    }

    // MARK: Data

    private var selectedEntries: [FileEntry] {
        entries.filter { selection.contains($0.path) }
    }

    private func findEntry(_ id: String) -> FileEntry? {
        entries.first { $0.path == id }
    }

    private var deleteTitle: String {
        let items = pendingDelete ?? []
        if items.count == 1, let item = items.first { return "Delete \(item.name)?" }
        return "Delete \(items.count) items?"
    }

    private func load() async {
        guard let client = state.client else { return }
        let folder = path
        isLoading = true
        do {
            let list = try await client.listFiles(containerID, path: folder)
            guard folder == path else { return }
            entries = list.filter { $0.name != "." && $0.name != ".." }
            errorText = nil
            selection = []
            lastGoodPath = folder
        } catch is CancellationError {
            // Folder changed.
        } catch {
            guard folder == path, !Task.isCancelled else { return }
            if let lastGoodPath, lastGoodPath != folder, !entries.isEmpty {
                // A link to a file, or a folder we may not read. Stay where we were.
                state.showError(error)
                path = lastGoodPath
            } else {
                entries = []
                errorText = error.localizedDescription
            }
        }
        isLoading = false
    }

    // MARK: Actions

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(path)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await upload(urls) }
    }

    private func upload(_ urls: [URL]) async {
        guard let client = state.client, !urls.isEmpty else { return }
        let folder = path
        var done = 0
        for url in urls {
            busyText = "Uploading \(url.lastPathComponent)…"
            do {
                // The folder exists, so the item lands inside it. Naming the
                // item itself would nest a folder that is already there.
                try await client.copyToContainer(containerID, from: url, path: folder)
                done += 1
            } catch {
                state.showError(error)
            }
        }
        busyText = nil
        if done > 0 {
            state.showToast(done == 1 ? "Uploaded \(urls[0].lastPathComponent)" : "Uploaded \(done) items", style: .success)
        }
        reloadToken += 1
    }

    private func download(_ items: [FileEntry]) {
        guard !items.isEmpty else { return }
        if items.count == 1, let item = items.first {
            let panel = NSSavePanel()
            panel.title = "Download \(item.name)"
            panel.nameFieldStringValue = item.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // The save panel already asked about replacing. Move the old item
            // to the Trash so a folder is replaced, not merged into.
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    state.showError(error)
                    return
                }
            }
            Task { await copyOut([(item, url, url)]) }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Choose a folder for \(items.count) items"
            panel.prompt = "Download"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            // Copying into the folder keeps each item's name.
            let pairs = items.map { ($0, folder, folder.appendingPathComponent($0.name)) }
            Task { await copyOut(pairs) }
        }
    }

    /// Items with the copy destination and where the result ends up.
    private func copyOut(_ pairs: [(FileEntry, URL, URL)]) async {
        guard let client = state.client else { return }
        var done = 0
        var lastURL: URL?
        for (item, destination, result) in pairs {
            busyText = "Downloading \(item.name)…"
            do {
                try await client.copyFromContainer(containerID, path: item.path, to: destination)
                done += 1
                lastURL = result
            } catch {
                state.showError(error)
            }
        }
        busyText = nil
        if done > 0 {
            state.showToast(done == 1 ? "Saved \(lastURL?.lastPathComponent ?? "file")" : "Saved \(done) items", style: .success)
            if let lastURL {
                NSWorkspace.shared.activateFileViewerSelecting([lastURL])
            }
        }
    }

    private func delete(_ items: [FileEntry]) async {
        guard let client = state.client, !items.isEmpty else { return }
        var done = 0
        for item in items {
            busyText = "Deleting \(item.name)…"
            do {
                try await client.deleteFile(containerID, path: item.path)
                done += 1
            } catch {
                state.showError(error)
            }
        }
        busyText = nil
        if done > 0 {
            state.showToast(done == 1 ? "Deleted \(items[0].name)" : "Deleted \(done) items", style: .success)
        }
        reloadToken += 1
    }
}

/// Table row for a file, with sortable fields.
private struct BrowserFileRow: Identifiable {
    let entry: FileEntry

    init(_ entry: FileEntry) {
        self.entry = entry
    }

    var id: String { entry.path }
    var name: String { entry.name }
    var size: UInt64 { entry.sizeBytes }
    var modified: Date { entry.modified ?? .distantPast }
    var permissions: String { entry.permissions }
}
