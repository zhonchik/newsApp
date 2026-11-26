# Technical decisions for Current

This record describes architecture and implementation constraints inferred from the code, regression tests, repository instructions, and merged changes through `479fac2`. User-visible contracts are recorded in [Product decisions](product-decisions.md).

## T1. On-device architecture and Apple targets

Use SwiftUI and SwiftData for the iOS, iPadOS, and macOS app. Fetch feeds and articles from the client with URLSession. Parse RSS and Atom with XMLParser, use SwiftSoup for HTML and public Telegram previews, and run bundled Mozilla Readability in an isolated WebKit document. The standard workflow requires no hosted reader service or API key.

Generate the Xcode project from `project.yml`. `Current` uses automatic CloudKit configuration with provisioned entitlements. `CurrentLocal` uses `LOCAL_ONLY`, disables CloudKit, and has its own bundle identifier. The supported deployment targets are iOS 17 and macOS 14.

Evidence: [project.yml](../project.yml), [CurrentApp](../App/CurrentApp.swift), and [FeedService](../App/FeedService.swift).

## T2. Separate library metadata, cached payloads, and local reading history

Use SwiftData for subscriptions, article metadata and positions, and the last selected queue article. Derive story identity from the publisher URL by dropping fragments and known tracking parameters while preserving meaningful query items. Consolidate duplicates and filter duplicate identities from visible snapshots. Store chronological ordering for new arrivals through queue positions and first-open ordering through read positions.

Use the local disk cache for article bodies and media. Migrate legacy bodies in batches and preserve article links and metadata during cache eviction. Keep the active root, linked documents, and per-visit offsets in a separate, atomically written local reading-session file. Use distinct visit keys so repeated URLs and late scroll callbacks cannot overwrite another visit.

Evidence: [Models](../App/Models.swift), [LibraryWorker](../App/LibraryWorker.swift), [ArticleIdentity](../ReaderContent/ArticleIdentity.swift), [ReaderHistory](../App/ReaderHistory.swift), [ReaderState](../App/ReaderState.swift), and [LibraryCacheTests](../Tests/ReaderRuntimeTests/LibraryCacheTests.swift).

## T3. Keep expensive work off the UI path

Open the store and prepare startup content asynchronously. Check saved history and launch cache early, with a legacy body lookup available before a full library scan. Publish immutable snapshots from the library worker to the UI. Keep WebKit and UI operations on the main actor. Use actors for fetching, preparation, cache work, and background model access. Batch imports, coalesce concurrent refresh work, and guard against stale navigation and rendering results. Keep refresh and cache warmup off the critical path for displaying saved content.

Evidence: [CurrentApp](../App/CurrentApp.swift), [LibraryWorker](../App/LibraryWorker.swift), [ReaderState](../App/ReaderState.swift), [ArticlePreparation](../App/ArticlePreparation.swift), and merged PRs `#8` and `#9`.

## T4. Share content rules across native and web rendering

Use format semantics and user settings for extraction, sanitization, and media normalization. Follow the feed-agnostic policy in [AGENTS.md](../AGENTS.md). Preserve story boundaries and run formatting and filtering against the document being presented. Reuse formatted bodies only when the source content, filters, and cached-media availability still match.

Render supported content as native blocks and fall back to a sanitized WebKit document for richer markup such as tables and glossary popovers. Keep publisher scripts disabled. Allow controlled YouTube embeds and route links through the reader's navigation policy. Apply scroll capture and restoration in both renderers.

Evidence: [ReaderPage](../App/ReaderPage.swift), [NativeArticleBody](../App/NativeArticleBody.swift), [ArticleWebView](../App/ArticleWebView.swift), [MediaCache](../App/MediaCache.swift), and [ReaderContent](../ReaderContent/ReaderContent.swift). Historical WebKit-only descriptions in the README predate the hybrid renderer.

## T5. Bound media caching and preserve working files on refresh

Apply least-recently-used eviction to managed content and media. Cap an individual cached media file at 80 MiB and also respect the available cache budget. Resolve normalized media URLs consistently across parsing, cache lookup, and rendering. Prefetch images and posters. Direct videos can stream and use byte-range requests for seeking, with background caching triggered by playback. Preserve cached media if forced refresh fails. YouTube player storage is separate from the managed cache.

Evidence: [MediaCache](../App/MediaCache.swift), [MediaRequest](../ReaderContent/MediaRequest.swift), [MediaURL](../ReaderContent/MediaURL.swift), [NativeArticleView](../App/NativeArticleView.swift), and [MediaCacheTests](../Tests/ReaderRuntimeTests/MediaCacheTests.swift).

## T6. Validate behavior at the appropriate runtime

Preserve behavior-specific regressions with synthetic fixtures. Use `ReaderContentTests` for portable content, identity, queue, and retry behavior. Use `ReaderRuntimeTests` on macOS for Apple-framework paths such as extraction, media cache, layout, and persistence. CI runs the Swift package tests and builds both schemes for iOS Simulator and macOS. Real-device behavior and provisioned CloudKit sync require separate device validation.

The cloud onboarding workflow uses a separate Linux Swift package under `/workspace/.newsapp-setup` to run the checked-in content tests. Keep that configuration outside the application package.

Evidence: [AGENTS.md](../AGENTS.md), [Package.swift](../Package.swift), [validation workflow](../.github/workflows/validate.yml), and this task's cloud onboarding record.
