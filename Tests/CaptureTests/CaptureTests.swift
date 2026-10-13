import XCTest
import Foundation
@testable import Tendedero

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor
final class CaptureTests: XCTestCase {
    private func fixture() throws -> (WebsiteCapture, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let model = WebsiteCapture(storage: root, preferences: defaults,
                                   session: URLSession(configuration: config), cookies: { [] })
        return (model, root, defaults)
    }
    func testLocalCopySurvivesSourceRemovalAndRestart() throws {
        let (model, root, defaults) = try fixture()
        let source = root.appendingPathComponent("input.png")
        try Data("fixture image".utf8).write(to: source)
        let id = try XCTUnwrap(model.stage(source))
        XCTAssertEqual(model.stage(source), id)
        XCTAssertEqual(model.records.count, 1)
        try FileManager.default.removeItem(at: source)
        let restored = WebsiteCapture(storage: root, preferences: defaults, cookies: { [] })
        XCTAssertEqual(restored.records.first?.id, id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.records[0].file))
    }
    func testPlacementFailureRetryDoesNotReupload() async throws {
        let (model, root, _) = try fixture()
        let source = root.appendingPathComponent("input.png")
        try Data("fixture image".utf8).write(to: source)
        let id = try XCTUnwrap(model.stage(source))
        model.selectedFolder = "f-test"
        var uploads = 0; var placements = 0
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/upload") {
                uploads += 1
                return (200, ["ok": true, "files": [["ok": true, "digest": String(repeating: "a", count: 64)]]])
            }
            placements += 1
            return placements == 1 ? (500, ["error": "failed"]) : (200, ["ok": true, "moved": 1])
        }
        await model.save(id)
        XCTAssertEqual(model.records[0].state, "待重试")
        XCTAssertNotNil(model.records[0].digest)
        await model.save(id)
        XCTAssertEqual(model.records[0].state, "已保存")
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(placements, 2)
    }
    func testExpiredLoginAndPerFileFailureStayRetryable() async throws {
        let (model, root, _) = try fixture()
        let source = root.appendingPathComponent("input.png")
        try Data("fixture image".utf8).write(to: source)
        let id = try XCTUnwrap(model.stage(source)); model.selectedFolder = "f-test"
        StubProtocol.handler = { _ in (302, [:]) }
        await model.save(id)
        XCTAssertEqual(model.records[0].state, "待重试")
        XCTAssertNil(model.records[0].digest)
        StubProtocol.handler = { _ in (200, ["ok": true, "files": [["ok": false, "error": "quota"]]]) }
        await model.save(id)
        XCTAssertEqual(model.records[0].state, "待重试")
        XCTAssertNil(model.records[0].digest)
    }
    func testNotesAreUploadedAndPlacedTogether() async throws {
        let (model, root, _) = try fixture()
        let source = root.appendingPathComponent("input.png")
        try Data("fixture".utf8).write(to: source)
        let id = try XCTUnwrap(model.stage(source)); model.selectedFolder = "f-test"
        model.edit(id, note: "我的备注", tags: "课程")
        var uploads = 0
        StubProtocol.handler = { req in
            if req.url!.path.hasSuffix("/upload") {
                uploads += 1
                return (200, ["ok": true, "files": [["ok": true, "digest": String(repeating: uploads == 1 ? "a" : "b", count: 64)]]])
            }
            return (200, ["ok": true, "moved": 2])
        }
        await model.save(id)
        XCTAssertEqual(uploads, 2)
        XCTAssertEqual(model.records[0].state, "已保存")
        XCTAssertNotNil(model.records[0].noteDigest)
    }
    func testCorruptLedgerIsNotOverwritten() throws {
        let (_, root, defaults) = try fixture()
        let ledger = root.appendingPathComponent("captures.json")
        let broken = Data("broken".utf8); try broken.write(to: ledger)
        let model = WebsiteCapture(storage: root, preferences: defaults, cookies: { [] })
        let source = root.appendingPathComponent("input.png"); try Data("fixture".utf8).write(to: source)
        XCTAssertNil(model.stage(source))
        XCTAssertEqual(try Data(contentsOf: ledger), broken)
    }
}
