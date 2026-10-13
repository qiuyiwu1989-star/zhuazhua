import XCTest
import AppKit
@testable import Tendedero

final class NoteProtocol: URLProtocol {
    static var status = 200
    static var reply: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject:Self.reply)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class NotesTests: XCTestCase {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zhua-notes-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func testDraftPersistsMarkdownAndAttachmentsAfterRestart() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let model = Notes(directory:root,telemetryEnabled:false)
        var note = TextNote(); note.markdown = "# 标题\n\n中文 **正文**"; note.title = "草稿"
        model.records = [note]; XCTAssertTrue(model.persist())
        let digest = String(repeating:"a",count:64)
        note.markdown += "\n![图片](/api/zhuazhua/image/\(digest))"
        model.edit(note)
        let restored = Notes(directory:root,telemetryEnabled:false)
        XCTAssertEqual(restored.records[0].markdown,note.markdown)
        XCTAssertEqual(restored.records[0].attachments,[digest])
        XCTAssertNil(restored.records[0].syncedAt)
    }
    func testDraftImageStaysInSeparateLocalAttachmentStore() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let model = Notes(directory:root,telemetryEnabled:false)
        let note = TextNote(); model.records = [note]
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let data = bitmap.representation(using:.png,properties:[:])!
        model.attachImageData(data,id:note.id)
        XCTAssertEqual(model.records[0].attachments.count,1)
        XCTAssertFalse(model.records[0].wantsSync)
        let digest = model.records[0].attachments[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("note-attachments/" + digest + ".png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("captures.json").path))
    }
    func testCorruptNotesLedgerIsPreserved() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("notes.json"); let corrupt = Data("broken ledger".utf8)
        try corrupt.write(to:file)
        let model = Notes(directory:root,telemetryEnabled:false); model.records = [TextNote()]
        XCTAssertFalse(model.persist()); XCTAssertEqual(try Data(contentsOf:file),corrupt)
    }
    func testConflictKeepsLocalDraftAndVersion() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let token = root.appendingPathComponent("token"); try Data("fake-test-token".utf8).write(to:token)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NoteProtocol.self]
        let model = Notes(directory:root,credentialURL:token,session:URLSession(configuration:configuration),telemetryEnabled:false)
        var n = TextNote(); n.markdown = "local unsent text"; n.version = 2; model.records = [n]
        NoteProtocol.status = 409; NoteProtocol.reply = ["code":"version_conflict", "current":["version":3]]
        await model.sync(n.id)
        XCTAssertEqual(model.records[0].markdown,n.markdown)
        XCTAssertEqual(model.records[0].version,2)
        XCTAssertNotNil(model.records[0].error); XCTAssertNil(model.records[0].syncedAt)
        XCTAssertEqual(Notes(directory:root,telemetryEnabled:false).records[0].markdown,n.markdown)
    }
    func testSuccessfulSyncAdvancesVersionOnlyAfterAck() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let token = root.appendingPathComponent("token"); try Data("fake-test-token".utf8).write(to:token)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NoteProtocol.self]
        let model = Notes(directory:root,credentialURL:token,session:URLSession(configuration:configuration),telemetryEnabled:false)
        var n = TextNote(); n.markdown = "**note**"; model.records = [n]
        NoteProtocol.status = 200; NoteProtocol.reply = ["ok":true,"note":["id":n.id,"version":1]]
        await model.sync(n.id)
        XCTAssertEqual(model.records[0].version,1); XCTAssertNotNil(model.records[0].syncedAt)
    }
    func testAttachmentReferencesDeduplicateAndRejectOtherPaths() {
        let digest = String(repeating:"b",count:64)
        let image = "![图](/api/zhuazhua/image/\(digest))"
        XCTAssertEqual(Notes.attachmentDigests(image + image),[digest])
        XCTAssertEqual(Notes.attachmentDigests("[不是图片](/api/zhuazhua/image/\(digest)) ![bad](file:///private/data)"),[])
    }
    func testBasicMarkdownBlocksKeepCodeLiteral() {
        let blocks = NoteBlock.parse("# Heading\n- item\n1. ordered\n> quote\n```swift\n<script>never run</script>\n```\n---")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .list("•"), .list("1."), .quote, .code, .rule])
        XCTAssertEqual(blocks[4].text, "<script>never run</script>")
    }
    func testFieldLimitsAndDraftSubmissionFlag() {
        var n = TextNote(); n.title = String(repeating:"a",count:513)
        XCTAssertNotNil(Notes.validationError(n)); n.title = "valid"
        XCTAssertNil(Notes.validationError(n)); XCTAssertFalse(n.wantsSync)
    }
    func testWrongAckDoesNotMarkSynced() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let token = root.appendingPathComponent("token"); try Data("fake-test-token".utf8).write(to:token)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [NoteProtocol.self]
        let model = Notes(directory:root,credentialURL:token,session:URLSession(configuration:configuration),telemetryEnabled:false)
        var n = TextNote(); n.markdown = "note"; model.records = [n]
        NoteProtocol.status = 200; NoteProtocol.reply = ["ok":true,"note":["id":UUID().uuidString,"version":1]]
        await model.sync(n.id)
        XCTAssertNil(model.records[0].syncedAt); XCTAssertEqual(model.records[0].version,0)
    }
    func testPreviewCannotOpenJavascriptLinks() {
        let rendered = MarkdownNotePreview.inline("[link](javascript:alert) <script>hello</script>")
        XCTAssertTrue(rendered.runs.allSatisfy { $0.link == nil })
    }
}
