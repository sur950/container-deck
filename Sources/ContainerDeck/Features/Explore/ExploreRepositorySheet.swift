import SwiftUI
import DeckCore

/// Tags of one Docker Hub repository, with Pull and Run per tag.
struct ExploreRepositorySheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let repository: HubRepository

    @State private var tags: [HubTag] = []
    @State private var nextPage: Int?
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var localReferences: Set<String>

    @State private var pullingTag: String?
    @State private var pullLines: [String] = []
    @State private var pullError: String?
    @State private var pullTask: Task<Void, Never>?
    @State private var pullProgress: PullProgress?
    @State private var showLog = false
    @State private var lastPulled: String?

    private let hub = DockerHubClient()

    init(repository: HubRepository, localReferences: Set<String>) {
        self.repository = repository
        _localReferences = State(initialValue: localReferences)
    }

    var body: some View {
        SheetScaffold(
            repository.fullName,
            subtitle: repository.description.isEmpty ? "Docker Hub repository" : repository.description,
            icon: repository.isOfficial ? .official : .images,
            width: 700,
            scrolls: false
        ) {
            infoRow
            tagList
            if pullingTag != nil || pullError != nil || !pullLines.isEmpty {
                pullPanel
            }
        } footer: {
            HStack(spacing: 10) {
                if let url = hubURL {
                    Link(destination: url) {
                        DeckLabel("Open on Docker Hub", icon: .openExternal)
                    }
                    .foregroundStyle(DS.accent)
                    .tint(DS.accent)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 620)
        .task { await loadFirstPage() }
        .onDisappear { pullTask?.cancel() }
        .onDeckDebugCommand { name, value in
            if name == "explore-pull", let tag = tags.first(where: { $0.name == value }) { pull(tag) }
            if name == "explore-log" { showLog = true }
        }
    }

    // MARK: - Header

    private var infoRow: some View {
        HStack(spacing: 10) {
            ExploreBadges(isOfficial: repository.isOfficial, isDownloaded: false)
            if repository.starCount > 0 || repository.pullCount > 0 {
                ExploreStats(stars: repository.starCount, pulls: repository.pullCount)
            }
            Spacer(minLength: 0)
            if !tags.isEmpty {
                Text(nextPage == nil ? tagCountText : "\(tagCountText) loaded")
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
            }
        }
    }

    private var tagCountText: String {
        tags.count == 1 ? "1 tag" : "\(tags.count) tags"
    }

    private var hubURL: URL? {
        let path = repository.isOfficial && !repository.fullName.contains("/")
            ? "_/\(repository.fullName)"
            : "r/\(repository.fullName)"
        return URL(string: "https://hub.docker.com/\(path)")
    }

    // MARK: - Tags

    @ViewBuilder
    private var tagList: some View {
        Group {
            if isLoading && tags.isEmpty {
                LoadingView("Loading tags")
            } else if let loadError, tags.isEmpty {
                EmptyState(icon: .error, title: "Could not load tags", message: loadError, actionTitle: "Try Again") {
                    Task { await loadFirstPage() }
                }
            } else if tags.isEmpty {
                EmptyState(icon: .tag, title: "No tags", message: "This repository has no tags to pull.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                            HubTagRow(
                                hubTag: tag,
                                isDownloaded: localReferences.contains(ImageRefMatch.normalize(reference(for: tag))),
                                isPulling: pullingTag == tag.name,
                                pullBusy: pullingTag != nil,
                                onPull: { pull(tag) },
                                onRun: { run(tag) }
                            )
                            if index < tags.count - 1 || nextPage != nil {
                                Divider().padding(.leading, 14)
                            }
                        }
                        if nextPage != nil {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .task(id: tags.count) { await loadMore() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .deckCard()
    }

    // MARK: - Pull panel

    private var pullPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let pullingTag {
                    ProgressView().controlSize(.small)
                    Text("Pulling \(repository.fullName):\(pullingTag)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let pullError {
                    ResourceErrorText(pullError)
                        .lineLimit(2)
                } else {
                    DeckIcon(.success, size: 14, color: DS.running)
                    Text(lastPulled.map { "Pulled \(repository.fullName):\($0)" } ?? "Pull finished")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
                    .buttonStyle(.borderless)
                    .disabled(pullLines.isEmpty)
                if pullingTag != nil {
                    Button("Stop") { pullTask?.cancel() }
                }
            }
            if pullingTag != nil {
                PullProgressBar(progress: pullProgress)
            }
            if showLog {
                ResourceLogView(lines: pullLines, placeholder: "Pull progress shows here.")
                    .frame(height: 96)
            }
        }
        .padding(14)
        .deckCard(radius: DS.smallRadius + 2)
    }

    // MARK: - Actions

    private func reference(for tag: HubTag) -> String {
        "\(repository.fullName):\(tag.name)"
    }

    private func pull(_ tag: HubTag) {
        guard let client = state.client, pullingTag == nil else { return }
        let ref = reference(for: tag)
        pullingTag = tag.name
        lastPulled = tag.name
        pullLines = []
        pullProgress = nil
        pullError = nil
        pullTask = Task {
            do {
                for try await line in client.pullImage(ref, platform: Self.pullPlatform(for: tag)) {
                    if let parsed = PullProgress.parse(line) { pullProgress = parsed }
                    ResourceLog.append(line, to: &pullLines)
                }
                if Task.isCancelled {
                    pullError = "Pull stopped."
                } else {
                    localReferences.insert(ImageRefMatch.normalize(ref))
                    state.showToast("Pulled \(ref)", style: .success)
                    Notifier.taskFinished(title: "Pulled \(ref)", body: "The image is ready to run.", link: .image(ref), whenInBackground: true)
                    state.resourcesChanged()
                }
            } catch {
                pullError = Task.isCancelled ? "Pull stopped." : (CLIFailure.message(in: pullLines) ?? error.localizedDescription)
            }
            pullingTag = nil
        }
    }

    /// This Mac's platform when the tag has it, else amd64 (Rosetta).
    /// Without `--platform` the tool fetches every platform in the index.
    static func pullPlatform(for tag: HubTag) -> String? {
        let host = ImagePlatform.host
        if tag.platforms.isEmpty || tag.platforms.contains(where: { $0 == host || $0.hasPrefix(host + "/") }) {
            return host
        }
        if tag.platforms.contains(where: { $0 == "linux/amd64" || $0.hasPrefix("linux/amd64/") }) {
            return "linux/amd64"
        }
        return nil
    }

    private func run(_ tag: HubTag) {
        let ref = reference(for: tag)
        let platform = Self.pullPlatform(for: tag)
        let appState = state
        dismiss()
        ResourceUsage.afterSheetCloses {
            // Native runs need no platform. amd64 only images run with Rosetta.
            appState.runRequest = RunRequest(options: RunOptions(image: ref, platform: platform == ImagePlatform.host ? nil : platform))
        }
    }

    // MARK: - Loading

    private func loadFirstPage() async {
        isLoading = true
        loadError = nil
        do {
            let page = try await hub.tags(repository.fullName, page: 1)
            tags = page.items
            nextPage = page.items.isEmpty ? nil : page.nextPage
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        isLoading = false
    }

    private func loadMore() async {
        guard let page = nextPage, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let next = try await hub.tags(repository.fullName, page: page)
            let known = Set(tags.map(\.id))
            tags += next.items.filter { !known.contains($0.id) }
            nextPage = next.items.isEmpty ? nil : next.nextPage
        } catch {
            if !Task.isCancelled {
                nextPage = nil
                state.showError(error)
            }
        }
        isLoadingMore = false
    }
}

private struct HubTagRow: View {
    let hubTag: HubTag
    let isDownloaded: Bool
    let isPulling: Bool
    let pullBusy: Bool
    let onPull: () -> Void
    let onRun: () -> Void

    private var architectures: [String] {
        var seen: [String] = []
        for platform in hubTag.platforms {
            let short = ResourceUsage.shortPlatform(platform)
            if !seen.contains(short) { seen.append(short) }
        }
        return seen
    }

    /// True when the tag has platforms and none of them is arm64.
    private var needsRosetta: Bool {
        !hubTag.platforms.isEmpty && !hubTag.platforms.contains { $0.contains("arm64") }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(hubTag.name)
                        .font(.body.monospaced().weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(hubTag.name)
                    if isDownloaded {
                        Pill("On this Mac", tint: DS.running)
                    }
                    if needsRosetta {
                        Pill("Needs Rosetta", tint: DS.warning)
                    }
                }
                HStack(spacing: 6) {
                    Text(hubTag.sizeBytes > 0 ? Format.bytes(hubTag.sizeBytes) : "Size unknown")
                    if !architectures.isEmpty {
                        Text("·").foregroundStyle(DS.textTertiary)
                        Text(architectures.joined(separator: ", "))
                            .lineLimit(1)
                            .help(hubTag.platforms.joined(separator: ", "))
                    }
                    Text("·").foregroundStyle(DS.textTertiary)
                    Text("Updated \(Format.relative(hubTag.lastUpdated))")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(DS.textSecondary)
            }
            Spacer(minLength: 8)
            Group {
                if isPulling {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: onPull) {
                        DeckLabel(isDownloaded ? "Pull Again" : "Pull", icon: .pull)
                    }
                    .disabled(pullBusy)
                }
            }
            .frame(width: 104, alignment: .trailing)
            Button(action: onRun) {
                DeckLabel("Run", icon: .play)
            }
            .disabled(isPulling)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
