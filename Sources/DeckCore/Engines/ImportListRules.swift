import Foundation

/// Rules for the Import screen list: search, selection counts, which engine
/// sections start open, and which per image states to keep after a run.
/// No UI here so the rules can be tested.
public enum ImportListRules {
    /// Several engines with this many images or fewer in total all start open.
    public static let smallTotal = 12
    /// With more images than `smallTotal`, sections up to this size start open
    /// and bigger ones start closed, so one big engine does not bury the others.
    public static let smallSection = 8

    // MARK: - Search

    /// True when the image name, tag or full reference contains every word of the query.
    /// An empty query matches everything.
    public static func matches(_ image: EngineImage, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = [image.reference, image.normalizedReference, image.shortName, image.tag]
            .joined(separator: " ")
            .lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    public static func filter(_ images: [EngineImage], query: String) -> [EngineImage] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return images }
        return images.filter { matches($0, query: trimmed) }
    }

    // MARK: - Selection

    /// How many of these images are selected.
    public static func selectedCount(_ images: [EngineImage], selection: Set<String>) -> Int {
        images.reduce(0) { $0 + (selection.contains($1.id) ? 1 : 0) }
    }

    /// Images that can be picked. Images already in Apple's container are not.
    public static func selectable(_ images: [EngineImage]) -> [EngineImage] {
        images.filter { !$0.alreadyHere }
    }

    /// "25 images", or "3 of 25 selected" once something is picked.
    public static func countText(selected: Int, total: Int) -> String {
        if selected > 0 { return "\(selected) of \(total) selected" }
        return total == 1 ? "1 image" : "\(total) images"
    }

    // MARK: - Sections

    /// Engine ids whose section starts open, from the image count per engine (in screen order).
    /// One engine: open. Several with a small total: all open. Otherwise small sections
    /// open and big ones closed. When every section is big, all start closed so the
    /// headers give an overview first.
    public static func defaultExpanded(_ counts: [(id: String, count: Int)]) -> Set<String> {
        let present = counts.filter { $0.count > 0 }
        if present.count <= 1 { return Set(present.map(\.id)) }
        let total = present.reduce(0) { $0 + $1.count }
        if total <= smallTotal { return Set(present.map(\.id)) }
        return Set(present.filter { $0.count <= smallSection }.map(\.id))
    }

    /// Whether a section is open: the person's choice when there is one, else the default.
    public static func isExpanded(
        _ id: String, saved: [String: Bool], defaults: Set<String>
    ) -> Bool {
        saved[id] ?? defaults.contains(id)
    }

    // MARK: - Already in Apple's store

    /// True when Apple's container has this image now: same full reference, and when both
    /// sides know their platforms, the engine image's architecture is among the local ones.
    /// The digest is not compared. A fresh pull or a local copy gets a new digest for the
    /// same tag, and the row should still say it is there.
    public static func isInStore(_ image: EngineImage, local: [ImageSummary]) -> Bool {
        let wanted = image.normalizedReference
        let arch = image.architecture.map(normalizedArchitecture)
        return local.contains { summary in
            guard ImageReference.normalize(summary.reference) == wanted else { return false }
            guard let arch, !summary.platforms.isEmpty else { return true }
            return summary.platforms.contains { platformArchitecture($0) == arch }
        }
    }

    /// Sets `alreadyHere` on every image from the current local list. Nothing else is kept
    /// from earlier, so an image deleted from Apple's store becomes selectable again.
    public static func markPresence(_ images: [EngineImage], local: [ImageSummary]) -> [EngineImage] {
        images.map { image in
            var copy = image
            copy.alreadyHere = isInStore(image, local: local)
            return copy
        }
    }

    /// "arm64" from "linux/arm64/v8". nil when the text has no architecture.
    static func platformArchitecture(_ text: String) -> String? {
        let parts = text.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return parts.first.map(normalizedArchitecture) }
        return normalizedArchitecture(parts[1])
    }

    static func normalizedArchitecture(_ value: String) -> String {
        switch value.lowercased() {
        case "x86_64", "x86-64": return "amd64"
        case "aarch64": return "arm64"
        default: return value.lowercased()
        }
    }

    // MARK: - Per image states

    /// After a run ends, keep only results (done and failed). Waiting, cancelled and
    /// anything still in progress goes away so rows look normal again.
    public static func keepingResults(_ steps: [String: ImportStep]) -> [String: ImportStep] {
        steps.filter { _, step in
            switch step {
            case .done, .failed: return true
            default: return false
            }
        }
    }

    /// After the local image list changed: a "done" row whose image is no longer in
    /// Apple's store goes back to normal. Failed results and running steps stay.
    public static func droppingGoneResults(_ steps: [String: ImportStep], images: [EngineImage]) -> [String: ImportStep] {
        let here = Set(images.filter(\.alreadyHere).map(\.id))
        return steps.filter { id, step in
            if case .done = step { return here.contains(id) }
            return true
        }
    }
}
