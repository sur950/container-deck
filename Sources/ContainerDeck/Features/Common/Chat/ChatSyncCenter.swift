import SwiftUI
import AppKit
import DeckCore

/// Whether a chat's history is being saved to its volume right now.
enum ChatSaveStatus: Equatable {
    /// Not checked yet this launch. Writes go to the cache as usual.
    case unknown
    case saving
    /// The person turned chat history off.
    case off
    /// The volume was removed (Volumes screen or the CLI).
    case volumeMissing
    /// An older sandbox, made before chat volumes, whose volume is not there.
    case notAttached
    /// The container service does not answer. New messages stay in memory.
    case serviceStopped

    var notice: (text: String, action: String)? {
        switch self {
        case .unknown, .saving: return nil
        case .off: return ("Chat history is off. This conversation won't be saved.", "Turn On")
        case .volumeMissing: return ("The chat history volume was removed. This conversation won't be saved.", "Create Volume")
        case .notAttached: return ("This sandbox has no chat history volume. This conversation won't be saved.", "Attach Volume")
        case .serviceStopped: return ("The container service is stopped. New messages won't be saved until it runs, and are lost if you quit first.", "Try Again")
        }
    }

    /// Writes may go to the cache (it only mirrors a volume that is there).
    var canWrite: Bool { self == .unknown || self == .saving }
}

/// Keeps chat caches and chat volumes in step, in the background. The volume is where history
/// lives. The cache (ChatHistory) only mirrors it so screens open instantly. Screens write the
/// cache and call `changed`. The volume gets the change a few seconds later, in one round trip.
/// No volume, or history turned off, means nothing is saved and the cache is deleted.
@MainActor
@Observable
final class ChatSyncCenter {
    static let shared = ChatSyncCenter()

    private(set) var statuses: [String: ChatSaveStatus] = [:]
    private(set) var syncing: Set<String> = []

    /// Set by the screens. Without a client nothing syncs.
    @ObservationIgnored var client: ContainerClient?

    struct Target {
        let history: ChatHistory
        let isEnabled: @MainActor () -> Bool
        /// How to reach the volume right now. nil skips the sync (sandbox gone).
        let transport: @MainActor () -> ChatSyncTransport?
        /// True once: the first use makes the volume. After that a missing volume was removed.
        let mayCreateVolume: @MainActor () -> Bool
        let didCreateVolume: @MainActor () -> Void
        /// What a missing volume means for this chat.
        let missingStatus: ChatSaveStatus
        /// Cache files the volume changed.
        let onChange: @MainActor (Set<String>) -> Void
        /// History is gone (off, or no volume): drop what came from the cache.
        let onDropped: @MainActor () -> Void
        /// Saving again: write the messages kept in memory meanwhile.
        let onRecovered: @MainActor () -> Void
    }

    @ObservationIgnored private var targets: [String: Target] = [:]
    @ObservationIgnored private var scheduled: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var again: Set<String> = []
    @ObservationIgnored private var syncedThisLaunch: Set<String> = []
    @ObservationIgnored private var lastCheck: [String: Date] = [:]
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    /// Changes go to the volume at most this often.
    @ObservationIgnored var debounce: Duration = .seconds(3)
    /// Retry while the service is not answering.
    @ObservationIgnored var retry: Duration = .seconds(20)
    /// A chat that shows again checks its volume when the last check is older than this.
    @ObservationIgnored var recheckAfter: TimeInterval = 15

    static let modelsTarget = "models"
    static func sandboxTarget(_ name: String) -> String { "sandbox:\(name)" }

    init() {
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ChatSyncCenter.shared.flushOnQuit() }
        }
    }

    func status(_ id: String) -> ChatSaveStatus { statuses[id] ?? .unknown }

    func canWrite(_ id: String) -> Bool {
        guard let target = targets[id], target.isEnabled() else { return false }
        return status(id).canWrite
    }

    func register(_ id: String, target: Target) {
        targets[id] = target
    }

    func unregister(_ id: String) {
        targets[id] = nil
        scheduled[id]?.cancel()
        scheduled[id] = nil
        statuses[id] = nil
        syncedThisLaunch.remove(id)
        lastCheck[id] = nil
    }

    func isRegistered(_ id: String) -> Bool { targets[id] != nil }

    /// A chat shows: the first time after launch, or when the last check is old, look at the
    /// volume (it may have been removed meanwhile). Turned off history is applied right away.
    func chatAppeared(_ id: String) {
        guard let target = targets[id] else { return }
        if !target.isEnabled() {
            turnOff(id)
            return
        }
        let stale = lastCheck[id].map { Date().timeIntervalSince($0) > recheckAfter } ?? true
        guard client != nil, !syncedThisLaunch.contains(id) || stale else { return }
        syncedThisLaunch.insert(id)
        Task { await syncNow(id) }
    }

    /// A conversation changed in the cache. Sends it to the volume soon.
    func changed(_ id: String) {
        schedule(id, after: debounce)
    }

    /// The "Save chat history" switch changed.
    func historySettingChanged(_ id: String) {
        Task { await applyHistorySetting(id) }
    }

    /// Off: drop the cache. On: check the volume and save what was typed meanwhile.
    /// Stays "off" until the sync works, so the recovery step runs.
    func applyHistorySetting(_ id: String) async {
        guard let target = targets[id] else { return }
        if target.isEnabled() {
            await syncNow(id)
        } else {
            turnOff(id)
        }
    }

    /// The notice's button.
    func performNoticeAction(_ id: String) async {
        guard let target = targets[id] else { return }
        switch status(id) {
        case .volumeMissing, .notAttached:
            guard let client, case .helper(let volume, let labels)? = target.transport() else { return }
            do {
                try await client.ensureVolume(volume, labels: labels)
                target.didCreateVolume()
            } catch {
                setStopped(id)
                return
            }
            await syncNow(id)
        default:
            await syncNow(id)
        }
    }

    private func turnOff(_ id: String) {
        guard let target = targets[id] else { return }
        scheduled[id]?.cancel()
        scheduled[id] = nil
        let wasOff = status(id) == .off
        statuses[id] = .off
        target.history.removeAll()
        if !wasOff { target.onDropped() }
    }

    private func schedule(_ id: String, after delay: Duration) {
        guard scheduled[id] == nil else { return }
        scheduled[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.scheduled[id] = nil
            await self.syncNow(id)
        }
    }

    /// One round trip: check the volume, send the queued changes, take the volume's files into the cache.
    func syncNow(_ id: String) async {
        guard let target = targets[id] else { return }
        guard target.isEnabled() else {
            turnOff(id)
            return
        }
        guard let client, let transport = target.transport() else { return }
        if syncing.contains(id) {
            again.insert(id)
            return
        }
        syncing.insert(id)
        defer { syncing.remove(id) }
        let previous = status(id)
        let history = target.history
        if case .helper(let volume, let labels) = transport {
            let exists: Bool
            do {
                exists = try await client.chatVolumeExists(volume)
            } catch {
                setStopped(id)
                return
            }
            if !exists {
                if target.mayCreateVolume() {
                    do {
                        try await client.createVolume(name: volume, labels: labels)
                        target.didCreateVolume()
                    } catch {
                        setStopped(id)
                        return
                    }
                } else {
                    // Removed: no saved history. Drop the cache so nothing shows from it.
                    lastCheck[id] = Date()
                    statuses[id] = target.missingStatus
                    history.removeAll()
                    if previous.canWrite { target.onDropped() }
                    return
                }
            }
        }
        let sentState = history.syncState()
        let ops = ChatVolumeSync.operations(state: sentState, local: history.localFiles())
        do {
            let remote = try await client.syncChatVolume(ops, transport: transport)
            let plan = ChatVolumeSync.merge(remote: remote, local: history.localFiles(), sentState: sentState, currentState: history.syncState())
            history.apply(plan, sentState: sentState)
            statuses[id] = .saving
            lastCheck[id] = Date()
            if !plan.changedFiles.isEmpty { target.onChange(plan.changedFiles) }
            if previous != .saving && previous != .unknown { target.onRecovered() }
        } catch {
            DebugAutomation.log("chat sync \(id) failed: \(error.localizedDescription)")
            setStopped(id)
            return
        }
        // Changes that came in while this sync ran.
        if again.remove(id) != nil || !history.syncState().pending.isEmpty {
            schedule(id, after: debounce)
        }
    }

    #if DEBUG
    /// Shows a status for snapshots. Only reached from DebugAutomation commands.
    func setDebugStatus(_ id: String, _ value: String) {
        let map: [String: ChatSaveStatus] = ["saving": .saving, "off": .off, "missing": .volumeMissing,
                                              "attach": .notAttached, "stopped": .serviceStopped]
        statuses[id] = map[value] ?? .unknown
    }
    #endif

    private func setStopped(_ id: String) {
        statuses[id] = .serviceStopped
        schedule(id, after: retry)
    }

    /// On quit, a quick last send of queued changes. Messages kept in memory while the
    /// service was stopped are not on disk, and the notice said so.
    func flushOnQuit() {
        guard let client else { return }
        var jobs: [(ChatSyncTransport, [ChatSyncOp])] = []
        for (id, target) in targets where status(id) == .saving {
            let state = target.history.syncState()
            guard !state.pending.isEmpty, let transport = target.transport() else { continue }
            jobs.append((transport, ChatVolumeSync.operations(state: state, local: target.history.localFiles())))
        }
        guard !jobs.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for (transport, ops) in jobs {
                _ = try? await client.syncChatVolume(ops, transport: transport)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}

/// Above the composer when history is not being saved: what is going on and one button.
struct ChatSaveNotice: View {
    let status: ChatSaveStatus
    var columnWidth: CGFloat = ChatLayout.columnWidth
    var horizontalPadding: CGFloat = Layout.pagePadding
    let action: () async -> Void
    @State private var working = false

    var body: some View {
        if let notice = status.notice {
            HStack(spacing: 10) {
                DeckIcon(status == .serviceStopped ? .warning : .info, size: 13, color: status == .serviceStopped ? DS.warning : DS.textSecondary)
                // No fixedSize: at a zero width probe it would grow one word per line.
                Text(notice.text)
                    .font(.callout)
                    .foregroundStyle(DS.textSecondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Button(notice.action) {
                        working = true
                        Task {
                            await action()
                            working = false
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.border, lineWidth: 1))
            .frame(maxWidth: columnWidth)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }
}
