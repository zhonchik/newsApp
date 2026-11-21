import XCTest
@testable import ReaderRuntime

final class ArticleExtractionTests: XCTestCase {
    func testExtractionExcludesAdjacentStoryWithMatchingHeadlineStyle() async throws {
        let page = """
        <meta property="og:title" content="Restoring the riverbank">
        <main>
          <section>
            <h1 class="headline large">Restoring the riverbank</h1>
            <p>\(prose("The requested story begins here."))</p>
            <figure><img src="/photos/riverbank.jpg" alt="Restored riverbank"></figure>
            <p>\(prose("The requested story ends here."))</p>
          </section>
          <section>
            <div class="large headline">Surveying the forest</div>
            <p>\(prose("This is the adjacent story."))</p>
          </section>
        </main>
        """

        let result = try await FeedService.extractArticle(page: page, url: "https://publisher.example/story")

        XCTAssertTrue(result.contains("The requested story begins here."))
        XCTAssertTrue(result.contains("The requested story ends here."))
        XCTAssertTrue(result.contains("https://publisher.example/photos/riverbank.jpg"))
        XCTAssertFalse(result.contains("Surveying the forest"))
        XCTAssertFalse(result.contains("This is the adjacent story."))
    }

    func testExtractionKeepsContinuationUnderSubheading() async throws {
        let page = """
        <meta property="og:title" content="Restoring the riverbank">
        <main>
          <section>
            <h1 class="headline large">Restoring the riverbank</h1>
            <p>\(prose("The first chapter begins here."))</p>
          </section>
          <section>
            <h2 class="headline large">Measuring the results</h2>
            <p>\(prose("The second chapter continues the same story."))</p>
          </section>
        </main>
        """

        let result = try await FeedService.extractArticle(page: page, url: "https://publisher.example/story")

        XCTAssertTrue(result.contains("The first chapter begins here."))
        XCTAssertTrue(result.contains("The second chapter continues the same story."))
    }

    private func prose(_ opening: String) -> String {
        opening + """
         Local volunteers recorded changes across the site over several months. The survey team compared observations from each visit, recorded the results in a field notebook, and discussed the findings with residents before publishing the report.
        """
    }
}
