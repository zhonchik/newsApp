# Product decisions for Current

This record describes supported behavior inferred from the current code, regression tests, and merged changes through `479fac2`. The available onboarding chat covers development setup. Separate product chats were unavailable for review.

## P1. One persistent reading queue

- Combine RSS, Atom, and public Telegram subscriptions into one queue. The library starts empty and the reader presents one article at a time.
- Put read history first, ordered by first opening, followed by unread stories in persisted queue order. Append new arrivals and order each incoming refresh batch oldest first across feeds. Existing batches keep their positions. Opening a queue article marks it as read. The unread count reflects the loaded queue independently of article rendering, and **Go to first unread** jumps to its first unread entry.
- A story keeps its identity across subscription deletion and re-addition. Tracking parameters alone do not make a second story. Meaningful query parameters can distinguish stories.

Evidence: [ReaderState](../App/ReaderState.swift), [LibraryWorker](../App/LibraryWorker.swift), [ReadHistoryTests](../Tests/ReaderContentTests/ReadHistoryTests.swift), [QueueAndRefreshTests](../Tests/ReaderContentTests/QueueAndRefreshTests.swift), and commits `e8efda8` and `de541d1`.

## P2. In-app links and resumable reading

- Open article links inside the reader. **Original article** opens the source in the system browser. A failed linked load leaves the current page readable and reports the error.
- Swipe right or press Left Arrow to pop a linked visit. At the root, the same action moves to the previous queue article. Swipe left or press Right Arrow to advance the queue and clear the linked stack. **Home** returns to the root and clears its linked visits.
- Save the active root, linked visits, article bodies, and a scroll offset for each visit locally across launches, including offline. Repeated visits to the same URL have independent offsets. Reloading a visit preserves its position. Selecting a different queue article discards the previous session. A temporarily incomplete library snapshot preserves the saved session.

Evidence: [ReaderState](../App/ReaderState.swift), [ReaderHistoryTests](../Tests/ReaderRuntimeTests/ReaderHistoryTests.swift), and merged PR `#16`. Older README notes about scroll offsets refer to behavior before this change.

## P3. Subscription settings and automatic updates

- List subscriptions alphabetically. Use dedicated screens for creation and editing. An existing subscription's name can change. Its type and address are displayed as read-only fields. Confirm deletion and retain saved articles.
- Pausing a subscription keeps its existing stories visible and continues collecting a hidden backlog. Resuming appends the backlog to the queue. Each subscription can hide user-entered repeated phrases in its reader presentation.
- Refresh automatically on startup, foreground activation, every five minutes while active, and when advancing past the end of the queue. Regular triggers share a one-minute cooldown. Keep the current selection during refresh. A successful refresh with zero arrivals is a success. Optional media prefetch failures leave a successful feed refresh successful.
- Pull down at the top of the reader, or scroll upward past the top on Mac, to reload the article. A failed reload keeps the available page readable.

Evidence: [SubscriptionsView](../App/SubscriptionsView.swift), [ReaderView](../App/ReaderView.swift), [ReaderState](../App/ReaderState.swift), [RefreshOutcomeTests](../Tests/ReaderContentTests/RefreshOutcomeTests.swift), and merged PR `#14`.

## P4. Preserve the article and its media

- Keep the story's text, meaningful formatting, links, subtitles, bylines, captions, and relevant images. Preserve useful feed text and lead images when extraction is incomplete. Exclude neighboring stories, site controls, semantic footers, and marked promotions while preserving ordinary article text.
- Keep glossary definitions attached to their terms. Preserve intended Telegram repetition while removing duplicate preview containers. Support Telegram photos and public direct video when available.
- Use inline video controls. Start direct video caching when playback begins. YouTube plays in its official embedded player. Preserve readable content and source links when media is unavailable.

Evidence: [ArticleExtractionTests](../Tests/ReaderRuntimeTests/ArticleExtractionTests.swift), [ReaderContentTests](../Tests/ReaderContentTests/ReaderContentTests.swift), [ContentRulesTests](../Tests/ReaderContentTests/ContentRulesTests.swift), [VideoAndTelegramTests](../Tests/ReaderContentTests/VideoAndTelegramTests.swift), and [MediaCacheTests](../Tests/ReaderRuntimeTests/MediaCacheTests.swift).

## P5. Responsive reading and user controls

- Prefer a saved, readable article at launch and keep the previous page available while preparing a new one. Restore the reading session before network access can affect it.
- Offer independent light and dark text and background colors with previews and reset. Follow system appearance and accessibility settings. Settings groups subscriptions, colors, and cache controls.
- Show usage for the managed article and media cache. Default to 512 MiB and offer limits from 64 to 8192 MiB. Cache eviction preserves the saved library and its article links. Offline images and videos depend on cached availability.
- Offer a local-only edition for users without CloudKit provisioning and a CloudKit edition for library sync. The local reading session is distinct from the synced queue selection.

Evidence: [CurrentApp](../App/CurrentApp.swift), [NativeArticleTests](../Tests/ReaderRuntimeTests/NativeArticleTests.swift), [SettingsView](../App/SettingsView.swift), [ThemeSettings](../App/ThemeSettings.swift), and [project.yml](../project.yml).
