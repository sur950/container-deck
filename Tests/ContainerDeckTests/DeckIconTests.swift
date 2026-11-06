import XCTest
import AppKit
import SwiftUI
@testable import ContainerDeck

@MainActor
final class DeckIconTests: XCTestCase {
    func testEverySymbolExistsOnThisMac() {
        for name in DeckIconName.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name.symbol, accessibilityDescription: nil),
                "\(name) maps to missing SF Symbol \(name.symbol)"
            )
        }
    }

    /// The app ships for macOS 15, so every symbol must come from SF Symbols 6 or older.
    func testEverySymbolIsAvailableOnMacOS15() throws {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let symbols = plist["symbols"] as? [String: String],
              let releases = plist["year_to_release"] as? [String: [String: String]] else {
            throw XCTSkip("Symbol availability list not found on this Mac")
        }
        func macOSVersion(_ year: String) -> Double? {
            guard let version = releases[year]?["macOS"] else { return nil }
            let parts = version.split(separator: ".")
            return Double("\(parts.first ?? "0").\(parts.count > 1 ? parts[1] : "0")")
        }
        for name in DeckIconName.allCases {
            guard let year = symbols[name.symbol] else {
                XCTFail("\(name.symbol) is not in the availability list")
                continue
            }
            let version = macOSVersion(year) ?? 99
            XCTAssertLessThanOrEqual(version, 15.0, "\(name.symbol) needs macOS \(version)")
        }
    }

    func testNoTwoIconsShareASymbol() {
        var seen: [String: DeckIconName] = [:]
        for name in DeckIconName.allCases {
            if let other = seen[name.symbol] {
                XCTFail("\(name) and \(other) both use \(name.symbol)")
            }
            seen[name.symbol] = name
        }
    }

    func testTwoToneIconsHaveASecondLayer() {
        // A two tone icon whose symbol has only one layer would silently show one color.
        for name in DeckIconName.allCases where name.tone != .solid {
            XCTAssertGreaterThan(layerCount(name.symbol), 1, "\(name) uses \(name.symbol), which has one layer")
        }
    }

    func testTemplateImagesAreTemplates() {
        for name in DeckIconName.allCases {
            guard let image = DeckIconImageCache.image(name, size: 15) else {
                XCTFail("No template image for \(name)")
                continue
            }
            XCTAssertTrue(image.isTemplate, "\(name) image is not a template")
            XCTAssertGreaterThan(image.size.width, 0)
        }
        // Image.deck must not crash for any icon.
        for name in DeckIconName.allCases { _ = Image.deck(name) }
    }

    func testIconsFitTheirBox() {
        for name in DeckIconName.allCases {
            for box in [CGFloat(12), 16, 26, 40] {
                let point = DeckIconMetrics.pointSize(name.symbol, box: box)
                let extent = point * DeckIconMetrics.extentRatio(name.symbol)
                XCTAssertLessThanOrEqual(extent, box * 1.16, "\(name) overflows a \(box) pt box")
                XCTAssertGreaterThan(point, box * 0.5, "\(name) is too small in a \(box) pt box")
            }
        }
    }

    /// Counts distinct palette colors when the symbol is drawn with three colors.
    private func layerCount(_ symbol: String) -> Int {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let image = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
                    .applying(.init(paletteColors: [.red, .green, .blue]))
              ),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
              ) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96))
        NSGraphicsContext.restoreGraphicsState()
        var found = Set<Int>()
        for x in 0..<96 {
            for y in 0..<96 {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.6 else { continue }
                if c.redComponent > 0.6, c.greenComponent < 0.4, c.blueComponent < 0.4 { found.insert(0) }
                if c.greenComponent > 0.6, c.redComponent < 0.4, c.blueComponent < 0.4 { found.insert(1) }
                if c.blueComponent > 0.6, c.redComponent < 0.4, c.greenComponent < 0.4 { found.insert(2) }
            }
        }
        return found.count
    }
}
