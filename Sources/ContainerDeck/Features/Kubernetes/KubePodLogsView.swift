import SwiftUI
import AppKit
import DeckCore

/// Live logs of one pod, read from the Kubernetes API.
struct KubePodLogsView: View {
    @Environment(AppState.self) private var state
    let pod: KubePod
    let cluster: KubeCluster
    let client: ContainerClient
    let store: KubernetesStore
    let onClose: () -> Void

    @State private var container = ""
    @State private var follow = true
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var streaming = false
    @State private var filter = ""

    init(pod: KubePod, cluster: KubeCluster, client: ContainerClient, store: KubernetesStore, onClose: @escaping () -> Void) {
        self.pod = pod
        self.cluster = cluster
        self.client = client
        self.store = store
        self.onClose = onClose
        _container = State(initialValue: pod.containers.first ?? "")
    }

    private var shown: [String] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                DeckIcon(.logs, size: 14)
                Text(pod.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if pod.containers.count > 1 {
                    Picker("Container", selection: $container) {
                        ForEach(pod.containers, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .popUpAppearanceRefresh()
                }
                if streaming && follow {
                    Pill("Live", tint: DS.running)
                }
                Spacer(minLength: 8)
                TextField("Filter", text: $filter, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.joined(separator: "\n"), forType: .string)
                } label: {
                    DeckIcon(.copy, size: 13)
                }
                .buttonStyle(.borderless)
                .help("Copy the log")
                Button {
                    lines = []
                } label: {
                    DeckIcon(.trash, size: 13)
                }
                .buttonStyle(.borderless)
                .help("Clear")
                Button {
                    onClose()
                } label: {
                    DeckIcon(.close, size: 12)
                }
                .buttonStyle(.borderless)
                .help("Close the log")
            }
            .padding(.horizontal, DS.pad)
            .padding(.vertical, 8)
            .background(DS.surfaceSunken)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(DS.textPrimary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, DS.pad)
                    .padding(.vertical, 8)
                }
                .overlay {
                    if let error {
                        EmptyState(icon: .warning, title: "No logs", message: error)
                    } else if lines.isEmpty {
                        Text(streaming ? "Waiting for log lines" : "No log lines")
                            .font(.callout)
                            .foregroundStyle(DS.textTertiary)
                    }
                }
                .onChange(of: lines.count) { _, _ in
                    guard follow, filter.isEmpty, !lines.isEmpty else { return }
                    proxy.scrollTo(shown.count - 1, anchor: .bottom)
                }
            }
            .background(DS.surfaceRaised)
        }
        .task(id: "\(pod.id)|\(container)|\(follow)") {
            await stream()
        }
    }

    private func stream() async {
        lines = []
        error = nil
        streaming = true
        defer { streaming = false }
        do {
            let connection = try await store.connection(cluster, client: client)
            let live = follow && pod.status == "Running"
            // One request: the last lines, then each new line the moment the pod writes it.
            // The stream reads over Network.framework, so nothing is held back (KubeHTTPStream).
            let source = connection.api.podLogs(namespace: pod.namespace, pod: pod.name, container: container, follow: live)
            // Batch updates so a chatty pod does not redraw on every line.
            let buffer = KubeLineBuffer()
            let flusher = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    append(buffer.take())
                }
            }
            defer { flusher.cancel() }
            for try await line in source {
                buffer.add(line)
            }
            append(buffer.take())
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func append(_ batch: [String]) {
        guard !batch.isEmpty else { return }
        lines.append(contentsOf: batch)
        if lines.count > KubernetesConfig.maxLogLines {
            lines.removeFirst(lines.count - KubernetesConfig.maxLogLines)
        }
    }
}

/// Lines waiting to be shown.
@MainActor
final class KubeLineBuffer {
    private var pending: [String] = []

    func add(_ line: String) {
        pending.append(line)
    }

    func take() -> [String] {
        defer { pending = [] }
        return pending
    }
}
