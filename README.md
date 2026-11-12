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
- System light/dark appearance, scalable native typography, selectable text, offline cached articles.

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

Collection runs at launch, on returning to the foreground, every five minutes while active, and on selecting the last article. Automatic triggers have a one-minute cooldown and concurrent refreshes are coalesced. Temporary connection failures retry once; persistent failures appear in the menu and are retried on subsequent updates. There is no refresh button. It does not continuously collect while the app is closed. Publisher feeds and Telegram public previews expose finite recent windows, so old items can be missed during long absences or pauses. Telegram media-only posts and private channels are not supported. Private channel access and reliable historical backfill need an authenticated Telegram client integration. Public preview parsing may need updates if Telegram changes its HTML.

Full-text extraction cannot guarantee access to paywalled, blocked or JavaScript-only content. A failure preserves original feed text and the source link. Full text is fetched when an RSS article is selected; unread items retain feed text until opened. Telegram posts retain message formatting and public preview photos. Existing RSS articles are enriched again when opened to restore formatting.

CloudKit sync is eventual. Story identity uses publisher URLs (excluding tracking parameters), so deleting and re-adding a subscription preserves saved stories and read state. Existing duplicates are consolidated during updates, and duplicate CloudKit arrivals are hidden in the queue until consolidation. CloudKit has no unique constraints, so concurrent imports can temporarily create duplicate records. Concurrent pause changes resolve through CloudKit synchronization. Reading position uses the most recently changed record; scroll offset within an article is not restored. Calendar-based pauses from tgRssBot are outside this initial version.

## Validation

GitHub Actions runs content, identity and retry regression tests and builds unsigned iOS Simulator and macOS targets. Apple builds and real-device iCloud sync require macOS and Apple signing; they cannot run in the Linux authoring environment.

## Repository

https://github.com/zhonchik/newsApp

The existing repository license is preserved. Mozilla Readability and SwiftSoup retain their upstream licenses.

## Reader controls

Use Menu → Go to first unread to return to the oldest unread position in the queue. Subscription deletion requires tapping the trash button and confirming; saved articles remain. Menu → Subscriptions → Hide repeated text configures phrases hidden from a subscription's reader view.

Article extraction completes before displaying a newly selected story. If extraction fails, the cached version is shown once and is not replaced mid-read. A short preparation indicator may appear on first opening. Images without dimensions reserve space to reduce layout movement. N+1 ad containers are removed while ordinary article text mentioning advertising remains.
