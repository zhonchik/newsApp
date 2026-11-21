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

    func testExtractionKeepsArticleMetadataAndCaptionButDropsSiteShortcutHint() async throws {
        let page = """
        <meta name="author" content="Morgan Lee"><main><article>
          <h1>The river survey</h1>
          <p>Results from the spring expedition</p>
          <div><a rel="author">Morgan Lee</a></div>
          <photo-view data-gallery='{"images":[{"src":"/photos/river.jpg","caption":"The <i>upper</i> river","credit":"Field team"}]}'></photo-view>
          <p>\(prose("Press Ctrl+Enter in the sample application."))</p>
          <div v-if="desktop">Flag an error by pressing Ctrl+Enter.</div>
        </article></main>
        """
        let result = try await FeedService.extractArticle(page: page, url: "https://publisher.example/story")
        for text in ["Results from the spring expedition", "Morgan Lee", "<figcaption>The upper river — Field team</figcaption>"] {
            XCTAssertEqual(result.components(separatedBy: text).count, 2)
        }
        XCTAssertTrue(result.contains("https://publisher.example/photos/river.jpg"))
        XCTAssertTrue(result.contains("Press Ctrl+Enter in the sample application."))
        XCTAssertFalse(result.contains("Flag an error"))
    }

    func testExtractionOmitsFooterControlsFromImageOnlyStory() async throws {
        let page = """
        <main><article>
          <figure><img src="https://publisher.example/photo.jpg"><figcaption>Field survey</figcaption></figure>
          <footer><span>Report a typo<br>Press Ctrl+Enter</span><div>Tap to report</div></footer>
        </article></main>
        """
        let result = try await FeedService.extractArticle(page: page, url: "https://publisher.example/story")
        XCTAssertTrue(result.contains("photo.jpg"))
        XCTAssertTrue(result.contains("Field survey"))
        XCTAssertFalse(result.contains("Report a typo"))
        XCTAssertFalse(result.contains("Tap to report"))
    }

    private func prose(_ opening: String) -> String {
        opening + """
         Local volunteers recorded changes across the site over several months. The survey team compared observations from each visit, recorded the results in a field notebook, and discussed the findings with residents before publishing the report.
        """
    }
}
