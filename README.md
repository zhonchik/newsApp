# Current

A universal SwiftUI news reader for iPhone, iPad and Mac. One article, room to read.

## Included

- One persistent reading queue across RSS, Atom and public Telegram channels. Newly discovered stories append at the end; their publication date never moves existing stories.
- One article on screen, horizontal swipe navigation, VoiceOver previous/next actions, and Mac arrow keys.
- Unread count across visible stories; opening an article marks it read.
- Article headings, paragraphs, lists, links, emphasis and images are retained in a sanitized HTML reader. Publisher scripts are disabled. Images load from publishers and may require connectivity; publisher page styling is replaced with system-aware reader styling.
- Last-selected article restored on launch. Refresh preserves your current article.
- Full article extraction using Mozilla Readability locally; feed text remains available when extraction fails.
- Pause a subscription while collecting new items into a persisted queue; resume appends its backlog to the end of the reading queue. Existing visible stories stay readable.
- Local SwiftData library with private CloudKit synchronization for articles, subscriptions, pause state and reading position.
- System light/dark appearance, scalable native typography, selectable text, offline cached articles while their data remains in the cache.

## Build the Apple app

Requires macOS, Xcode 16+, XcodeGen, iOS/iPadOS 17+ or macOS 14+.

```sh
brew install xcodegen
xcodegen generate
open Current.xcodeproj
```

### Free Apple Account: local-only installation

Choose the **CurrentLocal** scheme and target in Xcode. In Signing & Capabilities, select your **Personal Team**, leave automatic signing enabled, and set a unique bundle identifier (for example `com.yourname.Current.local`). Connect your iPhone, enable Developer Mode, select it as the destination, and press Run (⌘R).

This target explicitly disables CloudKit and has no iCloud or push notification entitlements. RSS, Telegram, extraction, offline storage, reading position and pause/resume work on device. Nothing syncs to other devices. Free provisioning expires after seven days; rebuild and reinstall through Xcode when needed. Keep the bundle identifier consistent to retain the same app container; deleting the app deletes its local library.

CurrentLocal installs as **Current Local** with a separate bundle identifier and library, so it can coexist with the iCloud edition. Switching editions does not migrate articles or subscriptions automatically.

### iCloud edition: paid developer team

Choose the **Current** scheme and target. Select your Apple development team. Change `com.currentreader.Current` and `iCloud.com.currentreader.Current` in `project.yml` to identifiers owned by your team, then regenerate. Enable iCloud/CloudKit and remote notifications in Signing & Capabilities. Sign into iCloud on each device using the same Apple ID. Deploy the development CloudKit schema to production before distribution. CloudKit requires compatible signing, provisioning and an enabled container; there is no claim of verified sync until tested with your account.

Run the Current scheme on an iPhone, iPad or My Mac. In Subscriptions, add a feed URL or public Telegram username. No sample stories are mixed into your library.

## Serverless architecture

The app downloads RSS/Atom and public Telegram pages directly with URLSession. Mozilla Readability runs locally in an isolated WebKit document; SwiftSoup parses Telegram HTML. No hosted reading service, API key or server URL is required. iCloud synchronizes the local library using your Apple account.

## Behavioral limits

Collection runs at launch, on returning to the foreground, every five minutes while active, and on selecting the last article. Automatic triggers have a one-minute cooldown and concurrent refreshes are coalesced. Temporary connection failures retry once; persistent failures appear in the menu and are retried on subsequent updates. There is no refresh button. On iOS, both editions also request opportunistic background feed refresh. The system controls delivery. Publisher feeds and Telegram public previews expose finite recent windows, so old items can be missed during long absences or pauses. Telegram video-only posts are supported when exposed in public previews; other media-only posts and private channels are not supported. Private channel access and reliable historical backfill need an authenticated Telegram client integration. Public preview parsing may need updates if Telegram changes its HTML.

Full-text extraction cannot guarantee access to paywalled, blocked or JavaScript-only content. A failure preserves original feed text and the source link. Full text and images are prepared during subscription updates; missing content is fetched when an article is selected. Telegram posts retain message formatting and public preview photos. Existing RSS articles are enriched again when opened to restore formatting.

CloudKit sync is eventual. Story identity uses publisher URLs (excluding tracking parameters), so deleting and re-adding a subscription preserves saved stories and read state. Existing duplicates are consolidated during updates, and duplicate CloudKit arrivals are hidden in the queue until consolidation. CloudKit has no unique constraints, so concurrent imports can temporarily create duplicate records. Concurrent pause changes resolve through CloudKit synchronization. Reading position uses the most recently changed record; scroll offset within an article is not restored. Calendar-based pauses from tgRssBot are outside this initial version.

## Validation

GitHub Actions runs content, identity and retry regression tests and builds unsigned iOS Simulator and macOS targets. Apple builds and real-device iCloud sync require macOS and Apple signing; they cannot run in the Linux authoring environment.

## Repository

https://github.com/zhonchik/newsApp

The existing repository license is preserved. Mozilla Readability and SwiftSoup retain their upstream licenses.

## Reader controls

Use the fast-forward toolbar button (Go to first unread) to return to the oldest unread position in the queue. Subscription deletion requires tapping the trash button and confirming; saved articles remain. Subscriptions → Hide repeated text configures phrases hidden from a subscription's reader view.

Articles are prepared sequentially in the background while the app is active, prioritizing the selected story and unread queue. Selecting a story immediately displays cached content without a network wait. If preparation has not finished yet, the feed content remains on screen; the prepared full text is available on reopening. Background preparation does not replace a page mid-read. Read articles always precede unread articles, with read history ordered by when articles were opened and unread stories ordered by arrival. Images without dimensions reserve space to reduce layout movement. N+1 ad containers are removed while ordinary article text mentioning advertising remains.

F1News gallery pages use a dedicated image-grid extractor, with full-size publisher images and a link to additional gallery pages. The repeated-text filter for @abbasgallyamovpolitics matches both the original notice and the “И РАСПРОСТРАНЕН” variant; existing default filters are upgraded automatically, while cleared/custom filters remain user-controlled.

## Reader performance, video previews and colors

HTML parsing, feed decoding, extraction-script preparation and reader sanitization run outside the main actor. Reader rendering compares immutable inputs before starting work and discards stale results after navigation. WebKit calls and SwiftData UI-context updates remain on the main actor. This follows [Apple’s responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness); verify scrolling and refresh with Instruments Hangs and Time Profiler on a device, especially with large libraries.

Telegram import selects one message body instead of concatenating duplicate preview elements. Refresh repairs cached posts that are still in the channel’s public preview window; older saved posts outside that window are not rewritten.

YouTube links and embeds use an inline YouTube player. Public Telegram videos use inline HTML video controls when the public preview exposes a direct HTTPS video source; unavailable sources retain a provider link. Playback does not autoplay. Publisher scripts and iframes are stripped; only generated YouTube frames can execute provider JavaScript.

Settings includes separate text and background color pickers for the light and dark reader themes, with samples and a reset action. Colors persist locally and follow the device appearance.

## Scrolling and media storage

The reader reuses one WebKit view across article switches and sets its native background before rendering, including dark appearance. The navigation bar uses a fixed inline layout, and the load-finished callback no longer resets an in-progress scroll. Queue ordering is cached between queue changes. SwiftData imports, duplicate consolidation, and article preparation saves run on a background model actor; the visible document remains an immutable snapshot.

Article text, images, and direct HTTPS videos share a local disk cache, with a configurable limit (512 MiB by default), least-recently-used eviction, and an 80 MiB per-media-file limit. Cached videos support byte-range requests for seeking. Uncached videos stream over HTTPS when playback starts, and that play event starts the background cache download. Opening an article does not prefetch video data. Larger videos still stream but are not cached. Image loading is lazy and decoding is asynchronous. The OS may purge the cache; it is separate from the saved article library.

YouTube uses its official embedded player and WebKit-managed website storage, not a downloadable/offline copy of the video. YouTube embeds require connectivity and may be blocked by the video owner, region, or provider. Telegram signed media URLs may expire; refreshing a public channel obtains current media links for posts still in its preview window.

Device validation: scroll during refresh and preparation with a large library; switch articles repeatedly in dark mode; start scrolling before images finish; verify inline YouTube/Telegram playback and seeking; reopen a cached image/video article offline. Use Instruments Hangs and Time Profiler to verify main-thread latency. CI builds alone do not establish smooth scrolling on a device.

## Startup, settings, and cache lifecycle

Library opening and SwiftData migration run away from the main actor. The reader receives explicit immutable queue snapshots from the library actor, instead of relying on another context’s query notifications to display the first article. Startup and article loads have visible progress/retry states. WebKit document loads and extraction have bounded recovery paths; WebKit/UI operations remain on the main actor as required by Apple, while network, parsing, cache I/O, and library work use background actors. Actors use Swift’s executor pool, not a dedicated thread per process.

Settings has separate **Subscriptions**, **Colors**, and **Cache** tabs. The cache tab shows the measured bytes of the managed text/media cache, lets you choose a 64–8192 MiB limit, and applies eviction when the limit is lowered. Permanent library metadata and YouTube-managed website storage are separate from that figure. Old installations migrate saved bodies into the local cache; article URLs, titles, subscriptions, queue positions, and read history remain in the library even after eviction.

Subscription updates store feed text, prepare full text where available, and cache images/posters. Opening an article reads cached text and images first and fetches missing data. Opening an article does not download video data: direct video caching begins on the first play event. YouTube continues to use its embedded player rather than an offline video file. Pull down at the top of an article (or scroll upward past the top on Mac) to fetch fresh text and images. A failed reload keeps the previously displayed article readable.

The unread count fades while updates run, turns soft red if an update fails, and returns to its default color after success. Reduce Motion disables the repeating fade. There is no separate update-failure toolbar button.

Validation now includes SwiftData runtime tests for startup snapshots and migration/eviction retaining article links, as well as content-cache serialization and eviction policy tests. Physical-device startup after upgrade, pull-to-refresh, playback-triggered caching, and scroll performance still require device validation.

Startup first reads the last article’s cache without opening the database. On upgrades from older versions, a single-record database read can display the legacy saved body before migration. The reader view stays mounted as the database opens, and maintenance/refresh is deferred until its first page commits. A successful update with zero new articles is explicitly successful; optional image/full-text prefetch failures no longer color the unread count red. Red indicates a feed fetch/import failure or a failed explicit article reload.

The initial reader displays a full-size, theme-colored “Preparing…” overlay through database initialization and first-page preparation. It disappears only after WebKit signals usable content/layout; failed preparation offers a retry instead of a blank screen. F1News RSS image URLs with the known duplicated `https://c.f1news.ru` origin are normalized before rendering and prefetching, including already-saved HTML.


The reader saves a short filtered text preview when displaying an article. At launch it can show that preview while the store opens and WebKit prepares the full article. Older libraries can supply the saved article directly from SwiftData. Legacy body migration runs in batches after the reader becomes usable and can resume during an iOS background processing task.

To profile an upgrade, install the prior build on a physical device, open an article, and install the new build over it using the same bundle identifier. Record the first launch and a subsequent terminated launch with Instruments App Launch and Points of Interest. Compare “First readable article” and “First WebKit display” alongside the cache-read and store-open intervals. Repeat with a legacy body, an evicted cache, and networking disabled.
