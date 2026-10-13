import XCTest
@testable import Tendedero

@MainActor
final class NoteFormattingTests: XCTestCase {
    func testTableAndEscapedPipes() {
        let blocks = NoteBlock.parse("| 模块 | 说明 |\n|---|:---:|\n| **记忆** | 保留\\|来源 |\n\n正文")
        guard case .table(let rows) = blocks.first?.kind else { return XCTFail("Expected table") }
        XCTAssertEqual(rows, [["模块", "说明"], ["**记忆**", "保留|来源"]])
        XCTAssertEqual(blocks.last?.text, "正文")
    }
    func testFencedTableStaysCode() {
        let blocks = NoteBlock.parse("```\n| a | b |\n|---|---|\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .code)
    }
    func testTitleDerivationAndManualOverride() throws {
        XCTAssertEqual(Notes.suggestTitle("导语\n\n# **我的主题**\n正文"), "我的主题")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = Notes(directory: root, telemetryEnabled: false)
        var note = TextNote(); note.markdown = "# 原标题"; note.title = "原标题"; note.automaticTitle = true
        model.records = [note]
        note.markdown = "# 新标题"; model.edit(note)
        XCTAssertEqual(model.records[0].title, "新标题")
        note = model.records[0]; note.title = "手动标题"; model.edit(note)
        note = model.records[0]; note.markdown = "# 另一标题"; model.edit(note)
        XCTAssertEqual(model.records[0].title, "手动标题")
        XCTAssertEqual(model.records[0].automaticTitle, false)
    }
}
