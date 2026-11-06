import Foundation
import DeckCore

/// Sandbox chats, one per sandbox. Lives for the whole app, so a conversation and a reply on its
/// way survive leaving the tab or the screen. Each sandbox's history lives in its `<name>-chat`
/// volume, with a local cache the screen reads right away (see ChatSyncCenter).
@MainActor
@Observable
final class SandboxChatStore {
    static let shared = SandboxChatStore()

    private(set) var messages: [String: [SandboxChatMessage]] = [:]
    /// Composer text and chosen model per sandbox.
    var drafts: [String: String] = [:]
    var models: [String: String] = [:]
    private(set) var sending: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Ids for the answer on its way and the error row, so the transcript keeps them stable.
    private(set) var pendingIDs: [String: UUID] = [:]
    private(set) var errorIDs: [String: UUID] = [:]

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loaded: Set<String> = []
    /// Sandboxes with messages kept only in memory (history off, no volume, service stopped).
    @ObservationIgnored private(set) var unsaved: Set<String> = []
    /// Messages that came from or went to the cache, per sandbox.
    @ObservationIgnored private var savedIDs: [String: Set<UUID>] = [:]
    /// Root of the chat caches. Each sandbox gets its own folder, the cache of its `<name>-chat` volume.
    @ObservationIgnored let root: URL
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let sync: ChatSyncCenter
    /// Sandboxes to look up. The app reads the live list. Tests pass their own.
    @ObservationIgnored var sandboxes: @MainActor () -> [Sandbox] = { SandboxRuntime.shared.sandboxes }

    init(root: URL = AIPaths().chats, defaults: UserDefaults = .standard, sync: ChatSyncCenter = .shared) {
        self.root = root
        self.defaults = defaults
        self.sync = sync
    }

    // MARK: Save chat history

    /// The sandbox's "Save chat history" switch: its Chat tab menu, else how it was made.
    func historyEnabled(_ name: String) -> Bool {
        if let value = (defaults.dictionary(forKey: PrefKey.sandboxChatHistory) as? [String: Bool])?[name] { return value }
        return sandboxes().first { $0.name == name }?.savesChatHistoryByDefault ?? true
    }

    func setHistoryEnabled(_ name: String, _ enabled: Bool) {
        storeHistorySwitch(name, enabled)
        sync.historySettingChanged(ChatSyncCenter.sandboxTarget(name))
    }

    private func storeHistorySwitch(_ name: String, _ enabled: Bool) {
        var values = defaults.dictionary(forKey: PrefKey.sandboxChatHistory) as? [String: Bool] ?? [:]
        values[name] = enabled
        defaults.set(values, forKey: PrefKey.sandboxChatHistory)
    }

    func saveStatus(_ name: String) -> ChatSaveStatus { sync.status(ChatSyncCenter.sandboxTarget(name)) }

    /// The notice's button: Turn On, Create Volume, Attach Volume or Try Again.
    func noticeAction(_ name: String) async {
        if saveStatus(name) == .off {
            storeHistorySwitch(name, true)
            await sync.applyHistorySetting(ChatSyncCenter.sandboxTarget(name))
        } else {
            await sync.performNoticeAction(ChatSyncCenter.sandboxTarget(name))
        }
    }

    /// Cache for one sandbox's chat volume.
    func history(for name: String) -> ChatHistory {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let folder = String(name.map { allowed.contains($0) ? $0 : "_" })
        return ChatHistory(directory: root.appendingPathComponent("sandboxes", isDirectory: true).appendingPathComponent(folder, isDirectory: true))
    }

    /// Reads the cache (instant) and starts a background sync with the sandbox's chat volume.
    func ensureLoaded(_ name: String) {
        connectSync(name)
        guard !loaded.contains(name) else { return }
        loaded.insert(name)
        migrateLegacyFile(name)
        guard messages[name]?.isEmpty ?? true, sync.canWrite(ChatSyncCenter.sandboxTarget(name)) else { return }
        let saved = readCache(name)
        savedIDs[name, default: []].formUnion(saved.map(\.id))
        if !saved.isEmpty { messages[name] = saved }
    }

    private func readCache(_ name: String) -> [SandboxChatMessage] {
        history(for: name).load(ChatHistory.sandboxKey(name)).map { message -> SandboxChatMessage in
            var item = SandboxChatMessage(role: message.role == .user ? .user : .assistant, content: message.text)
            item.id = message.id
            return item
        }
    }

    /// Before volumes, sandbox chats were single files in the chats folder.
    private func migrateLegacyFile(_ name: String) {
        let legacy = ChatHistory(directory: root).url(for: ChatHistory.sandboxKey(name))
        let target = history(for: name)
        guard FileManager.default.fileExists(atPath: legacy.path),
              target.load(ChatHistory.sandboxKey(name)).isEmpty,
              let data = try? Data(contentsOf: legacy),
              let file = try? JSONDecoder.chatFile(data) else { return }
        try? target.save(ChatHistory.sandboxKey(name), messages: file)
        try? FileManager.default.removeItem(at: legacy)
    }

    private func connectSync(_ name: String) {
        let id = ChatSyncCenter.sandboxTarget(name)
        if !sync.isRegistered(id) {
            let mounted = sandboxes().first { $0.name == name }?.chatVolume != nil
            sync.register(id, target: ChatSyncCenter.Target(
                history: history(for: name),
                isEnabled: { [weak self] in self?.historyEnabled(name) ?? true },
                transport: { [weak self] in self.flatMap { SandboxChatStore.transport(for: name, in: $0.sandboxes()) } },
                mayCreateVolume: { [weak self] in self?.mayMakeVolume(name) ?? false },
                didCreateVolume: { [weak self] in self?.didMakeVolume(name) },
                missingStatus: mounted ? .volumeMissing : .notAttached,
                onChange: { [weak self] _ in self?.reloadFromCache(name) },
                onDropped: { [weak self] in self?.dropSaved(name) },
                onRecovered: { [weak self] in self?.saveUnsaved(name) }
            ))
        }
        sync.chatAppeared(id)
    }

    /// Sandboxes made with the volume never make it again by themselves (a missing one was removed).
    /// Older ones, and ones made with history off, get theirs the first time it is needed.
    private func mayMakeVolume(_ name: String) -> Bool {
        guard let sandbox = sandboxes().first(where: { $0.name == name }), sandbox.chatVolume == nil else { return false }
        return !(defaults.stringArray(forKey: PrefKey.sandboxChatVolumesMade) ?? []).contains(name)
    }

    private func didMakeVolume(_ name: String) {
        var made = defaults.stringArray(forKey: PrefKey.sandboxChatVolumesMade) ?? []
        if !made.contains(name) { made.append(name) }
        defaults.set(made, forKey: PrefKey.sandboxChatVolumesMade)
    }

    private func reloadFromCache(_ name: String) {
        guard !sending.contains(name), !unsaved.contains(name) else { return }
        let saved = readCache(name)
        savedIDs[name, default: []].formUnion(saved.map(\.id))
        messages[name] = saved
    }

    /// History went away: nothing shows from the cache. This session's messages stay in memory.
    func dropSaved(_ name: String) {
        let ids = savedIDs[name] ?? []
        let kept = (messages[name] ?? []).filter { !ids.contains($0.id) }
        messages[name] = kept
        savedIDs[name] = []
        if kept.isEmpty { unsaved.remove(name) } else { unsaved.insert(name) }
    }

    /// Saving is back: merge memory with the volume's copy, then save.
    func saveUnsaved(_ name: String) {
        guard unsaved.contains(name) else { return }
        let stored = readCache(name)
        let storedIDs = Set(stored.map(\.id))
        messages[name] = stored + (messages[name] ?? []).filter { !storedIDs.contains($0.id) }
        save(name)
    }

    /// Running sandboxes that mount their chat volume are reached with `exec`. Everything else
    /// (stopped, or made before chat volumes) uses a helper container with `<name>-chat`.
    static func transport(for name: String, in sandboxes: [Sandbox]) -> ChatSyncTransport? {
        guard let sandbox = sandboxes.first(where: { $0.name == name }) else { return nil }
        if sandbox.isRunning, sandbox.chatVolume != nil {
            return .exec(containerID: sandbox.container.id, directory: SandboxConfig.chatPath)
        }
        return .helper(volume: sandbox.chatVolume ?? ChatVolumeSync.sandboxVolume(name), labels: ChatVolumeSync.sandboxVolumeLabels(name))
    }

    /// Adds a message without sending it (tests and snapshots).
    func append(_ message: SandboxChatMessage, to name: String) {
        messages[name, default: []].append(message)
    }

    /// Sends from inside the sandbox. The request keeps going if the person leaves the tab.
    func send(_ text: String, sandbox: Sandbox, model: String, client: ContainerClient) {
        let name = sandbox.name
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.isEmpty, !sending.contains(name) else { return }
        ensureLoaded(name)
        errors[name] = nil
        messages[name, default: []].append(SandboxChatMessage(role: .user, content: text))
        save(name)
        pendingIDs[name] = UUID()
        sending.insert(name)
        let history = messages[name] ?? []
        tasks[name] = Task {
            do {
                let reply = try await client.sandboxChat(sandbox, model: model, messages: history)
                guard !Task.isCancelled else { return }
                messages[name, default: []].append(SandboxChatMessage(role: .assistant, content: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
                save(name)
            } catch {
                guard !Task.isCancelled else { return }
                errorIDs[name] = UUID()
                errors[name] = error.localizedDescription
            }
            sending.remove(name)
            tasks[name] = nil
        }
    }

    /// Stops waiting for the answer. A reply that still comes back is dropped.
    func stop(_ name: String) {
        tasks[name]?.cancel()
        tasks[name] = nil
        sending.remove(name)
    }

    /// Clears the conversation from the cache and from the volume.
    func clear(_ name: String) {
        stop(name)
        messages[name] = []
        errors[name] = nil
        unsaved.remove(name)
        history(for: name).clear(ChatHistory.sandboxKey(name))
        sync.changed(ChatSyncCenter.sandboxTarget(name))
    }

    /// The sandbox is gone: forget its chat, its switch and the cache. The volume is removed by the caller.
    func remove(_ name: String) {
        stop(name)
        sync.unregister(ChatSyncCenter.sandboxTarget(name))
        history(for: name).removeAll()
        messages[name] = nil
        errors[name] = nil
        drafts[name] = nil
        models[name] = nil
        unsaved.remove(name)
        savedIDs[name] = nil
        loaded.remove(name)
        var switches = defaults.dictionary(forKey: PrefKey.sandboxChatHistory) as? [String: Bool] ?? [:]
        switches[name] = nil
        defaults.set(switches, forKey: PrefKey.sandboxChatHistory)
        defaults.set((defaults.stringArray(forKey: PrefKey.sandboxChatVolumesMade) ?? []).filter { $0 != name }, forKey: PrefKey.sandboxChatVolumesMade)
    }

    /// Writes the cache, and the volume soon after. Kept in memory when history is not being saved.
    func save(_ name: String) {
        let list = (messages[name] ?? []).filter { $0.role != .system }
        guard sync.canWrite(ChatSyncCenter.sandboxTarget(name)) else {
            if !list.isEmpty { unsaved.insert(name) }
            return
        }
        let saved = list.map { message in
            SavedChatMessage(id: message.id, role: message.role == .user ? .user : .assistant, text: message.content)
        }
        try? history(for: name).save(ChatHistory.sandboxKey(name), messages: saved)
        savedIDs[name, default: []].formUnion(list.map(\.id))
        unsaved.remove(name)
        sync.changed(ChatSyncCenter.sandboxTarget(name))
    }

    #if DEBUG
    /// Sample state for snapshots.
    func setDebugState(_ name: String, messages list: [SandboxChatMessage], sending isSending: Bool, error: String?) {
        stop(name)
        messages[name] = list
        if isSending {
            pendingIDs[name] = UUID()
            sending.insert(name)
        }
        errorIDs[name] = UUID()
        errors[name] = error
    }
    #endif
}

private extension JSONDecoder {
    /// Messages of an old single file chat.
    static func chatFile(_ data: Data) throws -> [SavedChatMessage] {
        struct File: Decodable { var messages: [SavedChatMessage] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(File.self, from: data).messages
    }
}
