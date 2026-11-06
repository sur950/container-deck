import XCTest
@testable import DeckCore

final class CountFormatTests: XCTestCase {
    func testSmallNumbersStayAsIs() {
        XCTAssertEqual(CountFormat.compact(0), "0")
        XCTAssertEqual(CountFormat.compact(7), "7")
        XCTAssertEqual(CountFormat.compact(999), "999")
    }

    func testThousands() {
        XCTAssertEqual(CountFormat.compact(1_000), "1K")
        XCTAssertEqual(CountFormat.compact(1_200), "1.2K")
        XCTAssertEqual(CountFormat.compact(1_049), "1K")
        XCTAssertEqual(CountFormat.compact(1_050), "1.1K")
        XCTAssertEqual(CountFormat.compact(9_960), "10K")
        XCTAssertEqual(CountFormat.compact(15_300), "15K")
        XCTAssertEqual(CountFormat.compact(15_500), "16K")
        XCTAssertEqual(CountFormat.compact(999_499), "999K")
    }

    func testMillionsAndUp() {
        XCTAssertEqual(CountFormat.compact(999_950), "1M")
        XCTAssertEqual(CountFormat.compact(1_000_000), "1M")
        XCTAssertEqual(CountFormat.compact(2_450_000), "2.5M")
        XCTAssertEqual(CountFormat.compact(12_345_678), "12M")
        XCTAssertEqual(CountFormat.compact(3_210_000_000), "3.2B")
        XCTAssertEqual(CountFormat.compact(4_000_000_000_000), "4T")
    }

    func testNegativeAndExtremes() {
        XCTAssertEqual(CountFormat.compact(-1_200), "-1.2K")
        XCTAssertFalse(CountFormat.compact(.max).isEmpty)
        XCTAssertFalse(CountFormat.compact(.min).isEmpty)
    }
}
