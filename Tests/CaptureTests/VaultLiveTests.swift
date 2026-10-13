import XCTest
@testable import Tendedero

final class VaultLiveTests: XCTestCase {
    @MainActor func testAuthorizedLibrarySync() async throws {
        guard ProcessInfo.processInfo.environment["ZHUA_LIVE_SYNC"] == "1" else {
            throw XCTSkip("Explicit opt-in required: writes real captures to the configured personal inbox")
        }
        let model = WebsiteCapture()
        XCTAssertFalse(model.records.isEmpty)
        for record in model.records {
            let success = await VaultSync.shared.sync(record.id, model: model)
            XCTAssertTrue(success, model.records.first(where: { $0.id == record.id })?.vaultError ?? "Sync failed")
        }
        if let first = model.records.first {
            let duplicate = await VaultSync.shared.sync(first.id, model: model)
            XCTAssertTrue(duplicate, "Retry must be idempotent")
        }
    }
}
