import XCTest
@testable import Tendedero

final class OCRTests: XCTestCase {
    func testTagsDeduplicateAndPreserveOrder() {
        XCTAssertEqual(CaptureTags.merge("项目, AI", "ai，项目；新标签\n工作"), "项目, AI, 新标签, 工作")
        XCTAssertEqual(CaptureTags.merge("", " ， ; "), "")
    }
    func testOldRecordDecodesAndChineseSearch() throws {
        let record = CaptureRecord(id: "test", source: "a", file: "b", name: "screenshot.png", created: Date())
        let old = try JSONEncoder().encode(record)
        var decoded = try JSONDecoder().decode(CaptureRecord.self, from: old)
        XCTAssertNil(decoded.ocrText)
        decoded.ocrText = "个人 AGI\n工作知识采集工具"
        XCTAssertTrue(decoded.matchesSearch("个人 agi"))
        XCTAssertTrue(decoded.matchesSearch("知识采集"))
        XCTAssertFalse(decoded.matchesSearch("个人 不存在"))
        XCTAssertEqual(decoded.searchExcerpt("知识"), "工作知识采集工具")
        let restored = try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(restored.ocrText, decoded.ocrText)
    }
    func testMissingImageFailsRatherThanEmptySuccess() async {
        do {
            _ = try await CaptureOCR.shared.recognize(file: "/nonexistent/capture-test.png")
            XCTFail("Missing image must report failure")
        } catch { }
    }
}
