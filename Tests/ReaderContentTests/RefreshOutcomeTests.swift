import XCTest
@testable import ReaderContent

final class RefreshOutcomeTests: XCTestCase {
    func testEmptySuccessfulUpdateIsNotAnError() {
        let outcome = RefreshOutcome()
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.message, "Up to date · no new articles")
    }
    func testSubscriptionFailureIsReportedAndNextSuccessClearsIt() {
        var failure = RefreshOutcome()
        failure.errors = ["Feed could not be downloaded"]
        XCTAssertTrue(failure.failed)
        XCTAssertEqual(failure.message, "Feed could not be downloaded")
        var next = RefreshOutcome()
        next.newArticles = 2
        XCTAssertFalse(next.failed)
        XCTAssertEqual(next.message, "Subscriptions updated")
    }
}
