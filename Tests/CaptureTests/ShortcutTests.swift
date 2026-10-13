import XCTest
import Carbon
@testable import Tendedero

@MainActor
final class ShortcutTests: XCTestCase {
    func testPerActionPersistenceAndClear() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let old = Shortcut(keyCode: kVK_ANSI_L, modifiers: [.control, .option], key: "l")
        CaptureAction.line.save(old, in: defaults)
        XCTAssertEqual(CaptureAction.line.shortcut(in: defaults), old)
        XCTAssertEqual(CaptureAction.region.shortcut(in: defaults), CaptureAction.region.standard)
        CaptureAction.line.save(nil, in: defaults)
        XCTAssertNil(CaptureAction.line.shortcut(in: defaults))
        CaptureAction.line.save(CaptureAction.line.standard, in: defaults)
        XCTAssertEqual(CaptureAction.line.shortcut(in: defaults), .standard)
    }
    func testDuplicateDetectionUsesPhysicalKeyAndModifiers() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let value = CaptureAction.region.standard!
        XCTAssertEqual(CaptureShortcuts.conflict(value, excluding: .line, defaults: defaults), .region)
        XCTAssertNil(CaptureShortcuts.conflict(value, excluding: .region, defaults: defaults))
        XCTAssertNil(CaptureShortcuts.conflict(Shortcut(keyCode: value.keyCode, modifiers: [.command, .option], key: "s"), excluding: .line, defaults: defaults))
    }
    func testSystemScreenshotKeysAreProtected() {
        for code in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            XCTAssertTrue(CaptureShortcuts.isSystemScreenshot(Shortcut(keyCode: code, modifiers: [.command, .shift], key: "4")))
        }
        XCTAssertFalse(CaptureShortcuts.isSystemScreenshot(CaptureAction.region.standard!))
    }
}
