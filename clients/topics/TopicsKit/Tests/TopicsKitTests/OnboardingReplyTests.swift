import XCTest
@testable import TopicsKit

final class OnboardingReplyTests: XCTestCase {
    func testReadsAFencedJSONBlock() {
        let reply = """
        I looked through about 280 threads.
        ```json
        {"gmail": "ok", "threads_scanned": 280, "areas": [{"name": "Work"}, {"name": "Dog"}]}
        ```
        """
        let scan = OnboardingReply.scan(reply)
        XCTAssertEqual(scan, .scanned(threads: 280, areas: ["Work", "Dog"]))
    }

    func testReportsGmailUnavailable() {
        let reply = #"```json {"gmail": "unavailable", "error": "The token expired."}```"#
        XCTAssertEqual(OnboardingReply.scan(reply), .unavailable("The token expired."))
    }

    func testAReplyWithoutJSONMeansGmailWasNotRead() {
        XCTAssertEqual(OnboardingReply.scan("I can't reach your mail right now."), .unavailable("I can't reach your mail right now."))
    }

    func testProposalsKeepTwoCoreAndSixMoreAndDropUnnamed() {
        let more = (1...8).map { #"{"name": "Extra \#($0)"}"# }.joined(separator: ",")
        let reply = """
        {"core": [{"name": "Work", "why": "Lots of investor updates", "about": "Scale VP",
          "on_your_mind": ["IC memo"], "people": ["Ana (partner)"], "instructions": "Be brief."},
          {"name": "Home"}, {"name": "Garden"}, {"name": " "}],
         "more": [\(more)]}
        """
        let proposals = OnboardingReply.proposals(reply)
        XCTAssertEqual(proposals.core.map(\.name), ["Work", "Home"])
        XCTAssertEqual(proposals.core[0].onYourMind, ["IC memo"])
        XCTAssertEqual(proposals.core[0].instructions, "Be brief.")
        XCTAssertEqual(proposals.more.count, 6)
    }

    func testNeverProposesTheReservedCoreTopic() {
        let proposals = OnboardingReply.proposals(#"{"core": [{"name": "Core"}, {"name": "Work"}], "more": []}"#)
        XCTAssertEqual(proposals.core.map(\.name), ["Work"])
    }
}
