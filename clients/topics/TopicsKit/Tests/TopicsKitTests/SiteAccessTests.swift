import Foundation
import XCTest
@testable import TopicsKit

/// How far each booking site has climbed: checked (no record), the owner
/// books from a link, or the owner signed in so the helper can book.
final class SiteAccessTests: XCTestCase {
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("sites-\(UUID()).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testASiteIsItsHostWithoutWWW() {
        XCTAssertEqual(SiteAccessStore.site(of: "https://www.resy.com/cities/sf/venues/lolo?date=2026-11-17"), "resy.com")
        XCTAssertEqual(SiteAccessStore.site(of: "resy.com"), "resy.com")
        XCTAssertEqual(SiteAccessStore.site(of: "https://Booksy.com/en-us/"), "booksy.com")
        XCTAssertNil(SiteAccessStore.site(of: "not a site"))
        XCTAssertNil(SiteAccessStore.site(of: ""))
    }

    func testAnUnknownSiteHasNoRecord() throws {
        let store = try SiteAccessStore(url: url)
        XCTAssertNil(store.access(for: "https://resy.com/x"))
    }

    func testRecordsPersistAndAreFoundByAnyURLOnTheSite() throws {
        let profile = UUID()
        let store = try SiteAccessStore(url: url)
        try store.record("https://www.resy.com/cities/sf", level: .signedIn, profileID: profile, name: "Resy")
        try store.record("booksy.com", level: .link)
        let reloaded = try SiteAccessStore(url: url)
        XCTAssertEqual(reloaded.access(for: "resy.com/anything")?.level, .signedIn)
        XCTAssertEqual(reloaded.access(for: "resy.com")?.profileID, profile)
        XCTAssertEqual(reloaded.access(for: "resy.com")?.name, "Resy")
        XCTAssertEqual(reloaded.access(for: "https://booksy.com/a")?.level, .link)
        XCTAssertEqual(reloaded.all.map(\.site), ["booksy.com", "resy.com"])
    }

    func testTheOwnersLatestChoiceWins() throws {
        let store = try SiteAccessStore(url: url)
        try store.record("resy.com", level: .signedIn, profileID: UUID())
        try store.record("resy.com", level: .link)
        XCTAssertEqual(store.access(for: "resy.com")?.level, .link)
        XCTAssertNil(store.access(for: "resy.com")?.profileID)
    }

    func testRecordingAnUnreadableSiteThrows() throws {
        let store = try SiteAccessStore(url: url)
        XCTAssertThrowsError(try store.record("???", level: .link))
    }

    func testTheHelperSeesEachSitesRung() throws {
        let store = try SiteAccessStore(url: url)
        XCTAssertEqual(store.summary, "(none yet)")
        try store.record("resy.com", level: .signedIn, profileID: UUID(), name: "Resy")
        try store.record("booksy.com", level: .link)
        XCTAssertEqual(store.summary, """
            - booksy.com: the owner books from your link
            - resy.com (Resy): the owner signed in
            """)
    }
}
