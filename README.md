# Current

A universal SwiftUI news reader for iPhone, iPad and Mac. One article, room to read.

## Included

- One oldest-to-newest stream across RSS, Atom and public Telegram channels.
- One article on screen, horizontal swipe navigation and accessible previous/next buttons.
- Last-selected article restored on launch. Refresh preserves your current article.
- Full article extraction using the same Readability library as tgRssBot; feed text remains available when extraction fails.
- Pause a subscription while collecting new items into a persisted queue; resume releases its backlog in publication order. Existing visible stories stay readable.
- Local SwiftData library with private CloudKit synchronization for articles, subscriptions, pause state and reading position.
- System light/dark appearance, scalable native typography, selectable text, offline cached articles.

## Build the Apple app

Requires macOS, Xcode 16+, XcodeGen, iOS/iPadOS 17+ or macOS 14+.

```sh
brew install xcodegen
xcodegen generate
open Current.xcodeproj
```

Select your Apple development team. Change `com.currentreader.Current` and `iCloud.com.currentreader.Current` in `project.yml` to identifiers owned by your team, then regenerate. Enable iCloud/CloudKit and remote notifications in Signing & Capabilities. Sign into iCloud on each device using the same Apple ID. Deploy the development CloudKit schema to production before distribution. CloudKit requires compatible signing, provisioning and an enabled container; there is no claim of verified sync until tested with your account.

Run the Current scheme on an iPhone, iPad or My Mac. In Subscriptions, enter the HTTPS URL of your reading service, then add a feed URL or public Telegram username. Service URL is device-local and must be configured on each device. No sample stories are mixed into your library.

## Reading service

The stateless Go service fetches public sources and extracts article text. It stores no library or Telegram credentials. The app contacts this service for updates and full text; cached articles remain readable without it. HTTPS article URLs only. Fetches are capped at 5 MiB with a 15-second timeout; network connections reject private addresses and revalidate redirect targets.

```sh
cd Service
go test -race ./...
go run .
```

Default bind is `127.0.0.1:8080`. Put it behind an HTTPS reverse proxy reachable by your Apple devices. Configure proxy authentication, rate limits and access controls before exposing it to the Internet; the service itself has no user authentication. `LISTEN_ADDR` changes its listener. The service makes direct outbound public HTTPS connections and requires DNS and Internet access.

Endpoints:

- `GET /feed?kind=rss&url=<encoded HTTPS feed URL>`
- `GET /feed?kind=telegram&url=<public username>`
- `GET /article?url=<encoded HTTPS article URL>`

## Behavioral limits

Collection runs at launch, on returning to the foreground, and on manual refresh. It does not continuously collect while the app is closed. Publisher feeds and Telegram public previews expose finite recent windows, so old items can be missed during long absences or pauses. Telegram media-only posts and private channels are not supported. Private channel access and reliable historical backfill need an authenticated Telegram client integration. Public preview parsing may need updates if Telegram changes its HTML.

Full-text extraction cannot guarantee access to paywalled, blocked or JavaScript-only content. A failure preserves original feed text and the source link. Full text is fetched when an RSS article is selected; unread items retain feed text until opened. Telegram posts retain their original message text.

CloudKit sync is eventual. Simultaneous imports on separate devices can create duplicates because CloudKit-backed SwiftData does not support unique constraints. Concurrent pause changes resolve through CloudKit synchronization. Reading position uses the most recently changed record; scroll offset within an article is not restored. Calendar-based pauses from tgRssBot are outside this initial version.

## Validation

GitHub Actions builds unsigned iOS Simulator and macOS targets, and runs Go tests and vet. Apple builds and real-device iCloud sync require macOS and Apple signing; they cannot run in the Linux authoring environment.

## Repository

https://github.com/zhonchik/newsApp

The existing repository license is preserved. Go dependencies retain their upstream licenses.
