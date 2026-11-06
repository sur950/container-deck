import SwiftUI
import Observation
import DeckCore

extension PrefKey {
    /// Keep the last N builds (Builds screen). Same key DeckCore reads when it trims.
    static let buildsHistoryLimit = BuildsConfig.historyLimitKey
}

/// Main actor mirror of `BuildCenter.shared` for the Builds screen and the Build sheet.
/// Updates are grouped, so a busy log redraws a few times a second at most.
@MainActor
@Observable
final class BuildsStore {
    static let shared = BuildsStore()

    private(set) var records: [BuildRecord] = []
    /// Goes up whenever any log gets new lines. Views showing a log read it.
    private(set) var logVersion = 0

    @ObservationIgnored let center: BuildCenter
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var lastStatus: [UUID: BuildStatus] = [:]
    @ObservationIgnored private let gate = UpdateGate()

    init(center: BuildCenter = .shared) {
        self.center = center
        records = center.allRecords()
        lastStatus = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.status) })
        let gate = self.gate
        center.addObserver { [weak self] _ in
            // Many log lines arrive at once. Only one update waits at a time.
            guard gate.claim() else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                gate.release()
                self?.refresh()
            }
        }
    }

    /// Gives the store a way to show toasts and reload lists after a build.
    func attach(_ state: AppState) {
        self.state = state
    }

    func record(_ id: UUID?) -> BuildRecord? {
        guard let id else { return nil }
        return records.first { $0.id == id }
    }

    func log(_ id: UUID) -> [String] {
        center.log(id)
    }

    var runningCount: Int { records.filter { $0.status == .running }.count }

    // MARK: - Actions

    @discardableResult
    func start(_ options: BuildOptions, client: ContainerClient, origin: BuildOrigin = .buildsScreen) -> UUID {
        let id = center.start(options, client: client, origin: origin)
        refresh()
        return id
    }

    @discardableResult
    func rebuild(_ record: BuildRecord, client: ContainerClient) -> UUID {
        start(record.spec.options, client: client, origin: .buildsScreen)
    }

    func cancel(_ id: UUID) {
        center.cancel(id)
    }

    func remove(_ ids: [UUID]) {
        center.remove(ids)
        refresh()
    }

    func clearFinished() {
        center.clearFinished()
        refresh()
    }

    func applyHistoryLimit() {
        center.applyHistoryLimit()
        refresh()
    }

    // MARK: - Updates

    func refresh() {
        let fresh = center.allRecords()
        for record in fresh {
            let before = lastStatus[record.id]
            if before == .running && record.status.isFinished {
                finished(record)
            }
            lastStatus[record.id] = record.status
        }
        if fresh != records {
            withAnimation(.easeInOut(duration: 0.2)) { records = fresh }
        }
        logVersion &+= 1
    }

    /// Lists reload after a good build. Builds started on the Builds screen also say so.
    /// The Build sheet and Compose show their own result.
    private func finished(_ record: BuildRecord) {
        if record.status == .succeeded {
            state?.resourcesChanged()
        }
        guard record.origin == .buildsScreen, let state else { return }
        switch record.status {
        case .succeeded:
            state.showToast("Built \(record.title)", style: .success)
            Notifier.taskFinished(title: "Built \(record.title)", body: "The build finished.")
        case .failed:
            state.showToast("Build of \(record.title) failed", style: .error)
            Notifier.taskFinished(title: "Build failed", body: record.message ?? record.title)
        default:
            break
        }
    }
}

/// Lets only one pending update through at a time. Safe from any thread.
private final class UpdateGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if waiting { return false }
        waiting = true
        return true
    }

    func release() {
        lock.lock()
        waiting = false
        lock.unlock()
    }
}
