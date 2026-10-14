import XCTest
@testable import Tendedero

final class AppUpdateTests: XCTestCase {
    func testSemanticOrdering() {
        XCTAssertTrue(AppRelease.newer("0.2.10", than: "0.2.9"))
        XCTAssertFalse(AppRelease.newer("0.2.3", than: "0.2.3"))
        XCTAssertFalse(AppRelease.newer("0.2.2", than: "0.2.3"))
        XCTAssertFalse(AppRelease.newer("invalid", than: "0.2.3"))
    }
    func testDownloadMustMatchOfficialVersionAsset() {
        let name = "ZhuaZhua-0.2.3-macOS.zip"
        func release(_ url: String) -> AppRelease {
            AppRelease(tag_name: "v0.2.3", html_url: "", body: nil, draft: false, prerelease: true,
                       assets: [.init(name: name, browser_download_url: url)])
        }
        XCTAssertNotNil(release("https://github.com/qiuyiwu1989-star/zhuazhua/releases/download/v0.2.3/" + name).downloadURL)
        XCTAssertNil(release("https://example.com/" + name).downloadURL)
        XCTAssertNil(release("https://github.com/other/repo/releases/download/v0.2.3/" + name).downloadURL)
    }
}
