import XCTest
import DeckCore
@testable import ContainerDeck

final class AIModelsLibrarySortTests: XCTestCase {
    private func row(_ name: String, params: UInt64? = nil, size: UInt64? = nil, downloads: Int = 0, updated: Double? = nil, rank: Int) -> AILibraryRow {
        AILibraryRow(model: HFModel(id: "mlx-community/\(name)", downloads: downloads, lastModified: updated.map(Date.init(timeIntervalSince1970:)), parameters: params),
                     size: size, rank: rank)
    }

    private func sorted(_ rows: [AILibraryRow], _ column: AILibraryColumn, ascending: Bool) -> [String] {
        rows.sorted(using: AILibraryComparator(AILibrarySort(column: column, ascending: ascending))).map(\.model.name)
    }

    func testParametersSortByCountNotText() {
        let rows = [
            row("big-35B", params: 35_000_000_000, rank: 0),
            row("small-596M", params: 596_000_000, rank: 1),
            row("mid-4B", params: 4_000_000_000, rank: 2),
            row("huge-235B", params: 235_000_000_000, rank: 3),
            row("unknown", rank: 4)
        ]
        XCTAssertEqual(rows.map { $0.model.parameterText ?? "-" }, ["35B", "596M", "4.0B", "235B", "-"])
        XCTAssertEqual(sorted(rows, .parameters, ascending: true), ["small-596M", "mid-4B", "big-35B", "huge-235B", "unknown"])
        XCTAssertEqual(sorted(rows, .parameters, ascending: false), ["huge-235B", "big-35B", "mid-4B", "small-596M", "unknown"], "unknown stays last")
    }

    func testSizesDownloadsAndDates() {
        let rows = [
            row("a", size: 2_280_000_000, downloads: 10, updated: 300, rank: 0),
            row("b", size: 984_000_000, downloads: 5_000, updated: 100, rank: 1),
            row("c", downloads: 300, rank: 2)
        ]
        XCTAssertEqual(sorted(rows, .size, ascending: true), ["b", "a", "c"])
        XCTAssertEqual(sorted(rows, .size, ascending: false), ["a", "b", "c"])
        XCTAssertEqual(sorted(rows, .downloads, ascending: false), ["b", "c", "a"])
        XCTAssertEqual(sorted(rows, .downloads, ascending: true), ["a", "c", "b"])
        XCTAssertEqual(sorted(rows, .updated, ascending: false), ["a", "b", "c"])
        XCTAssertEqual(sorted(rows, .updated, ascending: true), ["b", "a", "c"])
    }

    func testBits() {
        XCTAssertEqual(AILibrarySort.bits("4bit"), 4)
        XCTAssertEqual(AILibrarySort.bits("8bit"), 8)
        XCTAssertEqual(AILibrarySort.bits("bf16"), 16)
        XCTAssertEqual(AILibrarySort.bits("mxfp4"), 4)
        XCTAssertNil(AILibrarySort.bits("dwq"))
        XCTAssertNil(AILibrarySort.bits(nil))
        let rows = [row("x-8bit", rank: 0), row("y-dwq", rank: 1), row("z-4bit", rank: 2), row("w-bf16", rank: 3)]
        XCTAssertEqual(sorted(rows, .bits, ascending: true), ["z-4bit", "x-8bit", "w-bf16", "y-dwq"])
        XCTAssertEqual(sorted(rows, .bits, ascending: false), ["w-bf16", "x-8bit", "z-4bit", "y-dwq"])
    }

    func testNamesAndTies() {
        let rows = [row("Qwen3-14B", rank: 0), row("Qwen3-4B", rank: 1), row("gemma", rank: 2)]
        XCTAssertEqual(sorted(rows, .model, ascending: true), ["gemma", "Qwen3-4B", "Qwen3-14B"])
        XCTAssertEqual(sorted(rows, .model, ascending: false), ["Qwen3-14B", "Qwen3-4B", "gemma"])
        // Same value: keep the order Hugging Face sent, in both directions.
        let ties = [row("first", size: 1, rank: 0), row("second", size: 1, rank: 1)]
        XCTAssertEqual(sorted(ties, .size, ascending: true), ["first", "second"])
        XCTAssertEqual(sorted(ties, .size, ascending: false), ["first", "second"])
    }

    func testSavedSortAndStatusText() {
        XCTAssertEqual(AILibrarySort.browseDefault.phrase, "most downloaded first")
        XCTAssertEqual(AILibrarySort(column: .size, ascending: true).phrase, "sorted by size, smallest first")
        XCTAssertEqual(AILibrarySort(column: .updated, ascending: false).phrase, "sorted by date, newest first")
        XCTAssertEqual(AILibrarySort(rawValue: "size:asc"), AILibrarySort(column: .size, ascending: true))
        XCTAssertEqual(AILibrarySort(column: .bits, ascending: false).rawValue, "bits:desc")
        XCTAssertNil(AILibrarySort(rawValue: "nope:asc"))
        XCTAssertNil(AILibrarySort(rawValue: "size"))
    }

    func testLocalModels() {
        let a = LocalModel(repo: "mlx-community/B-4bit", folder: URL(fileURLWithPath: "/a"), modelPath: "/a", sizeBytes: 500, isComplete: true, modified: nil, source: .library)
        let b = LocalModel(repo: "mlx-community/A-8bit", folder: URL(fileURLWithPath: "/b"), modelPath: "/b", sizeBytes: 900, isComplete: true,
                           modified: Date(timeIntervalSince1970: 10), source: .huggingFaceCache)
        XCTAssertEqual([a, b].sorted(using: AILocalComparator(column: .model)).map(\.name), ["A-8bit", "B-4bit"])
        XCTAssertEqual([a, b].sorted(using: AILocalComparator(column: .size, order: .reverse)).map(\.name), ["A-8bit", "B-4bit"])
        XCTAssertEqual([a, b].sorted(using: AILocalComparator(column: .updated, order: .forward)).map(\.name), ["A-8bit", "B-4bit"], "unknown date last")
        XCTAssertEqual([a, b].sorted(using: AILocalComparator(column: .location)).map(\.name), [AppConfig.appName < "Hugging Face cache" ? "B-4bit" : "A-8bit", AppConfig.appName < "Hugging Face cache" ? "A-8bit" : "B-4bit"])
    }
}
