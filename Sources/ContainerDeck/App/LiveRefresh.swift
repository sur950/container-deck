import SwiftUI
import AppKit
import DeckCore

// The shared refresh pattern for resource screens (Images, Volumes, Networks, Machines):
// a light poll only while the main window is on screen, plus one check when the app
// comes back to the front, so changes made in Terminal show up without Refresh.

extension View {
    /// Runs `action` every `interval` seconds while this view and the main window are on screen,
    /// and once when the app becomes active. The first load stays with the screen's own `.task`.
    func autoRefresh(every interval: Double = 10, perform action: @escaping @MainActor () async -> Void) -> some View {
        modifier(AutoRefresh(interval: interval, action: action))
    }
}

private struct AutoRefresh: ViewModifier {
    let interval: Double
    let action: @MainActor () async -> Void

    func body(content: Content) -> some View {
        content
            .task(id: AppActivity.shared.windowVisible) {
                guard AppActivity.shared.windowVisible else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    if Task.isCancelled || !AppActivity.shared.windowVisible { break }
                    await action()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await action() }
            }
    }
}

/// Which containers use which volume and network. One `inspect` of all containers,
/// shared by the Volumes and Networks screens, and only redone when the container list
/// changed (ids or run state), not on every poll.
@MainActor
@Observable
final class ContainerUsage {
    static let shared = ContainerUsage()

    private(set) var volumeUsers: [String: [String]] = [:]
    private(set) var networkUsers: [String: [String]] = [:]

    @ObservationIgnored private var signature: [String]?
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    private init() {}

    /// Inspects again when the feed's containers changed since last time, or when `force` is set.
    func refresh(client: ContainerClient?, force: Bool = false) async {
        guard let client else { return }
        let feed = BackgroundServices.shared
        guard feed.hasLoaded else { return }
        let containers = feed.containers
        let next = containers.map { "\($0.id)|\($0.state)" }
        if !force, next == signature { return }
        if let running = inFlight {
            await running.value
            if !force, next == signature { return }
        }
        let task = Task { @MainActor in
            if containers.isEmpty {
                self.apply(volumes: [:], networks: [:])
                self.signature = next
                return
            }
            guard let details = try? await client.inspectContainers(containers.map(\.id)) else { return }
            self.apply(volumes: ContainerOutputParser.volumeUsers(details), networks: ContainerOutputParser.networkUsers(details))
            self.signature = next
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func apply(volumes: [String: [String]], networks: [String: [String]]) {
        if volumes != volumeUsers { volumeUsers = volumes }
        if networks != networkUsers { networkUsers = networks }
    }
}
