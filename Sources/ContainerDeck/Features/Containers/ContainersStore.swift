import SwiftUI
import DeckCore

/// Helpers for the Containers list. The list itself comes from the shared feed
/// (`BackgroundServices.containers`) and stats from `StatsSampler`, so this screen
/// runs no loop of its own.
@MainActor
enum ContainersStore {
    /// Helper containers the app starts for itself (volume browsing) stay hidden.
    nonisolated static func isHelper(_ container: ContainerSummary) -> Bool {
        container.labels["deck.helper"] != nil
    }

    /// Apple's image builder (BuildKit). `container build` starts it and needs it,
    /// so it is tagged in the list and never removed by Remove Stopped.
    nonisolated static func isBuilder(_ container: ContainerSummary) -> Bool {
        container.labels["com.apple.container.resource.role"] == "builder"
            || container.labels["com.apple.container.plugin"] == "builder"
    }

    /// Stopped containers that Remove Stopped may delete. Leaves the builder alone.
    static func removableStopped(_ containers: [ContainerSummary]) -> [ContainerSummary] {
        containers.filter { !$0.isRunning && !isBuilder($0) }
    }
}

/// Remembers the last row order while sorting by a live value (CPU, memory), so rows
/// only move when the values really differ. Kept outside SwiftUI state on purpose:
/// updating it while the view draws must not cause another draw.
@MainActor
final class LiveRowOrder {
    private var previous: [String] = []
    private var key = ""

    /// `key` names the sort (column and direction). A new key starts fresh.
    func order(_ items: [(id: String, value: Double)], key: String, descending: Bool,
               threshold: @escaping (Double, Double) -> Double) -> [String] {
        if key != self.key {
            self.key = key
            previous = []
        }
        let result = StableOrder.order(previous: previous, items: items, descending: descending, threshold: threshold)
        previous = result
        return result
    }
}
