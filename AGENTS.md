# Repository instructions

## Keep the repository feed-agnostic

- Base article extraction, rendering, and media handling on shared formats, markup, and user-provided settings. Do not hard-code rules or defaults for individual feeds, publishers, or channels, including their domains, URLs, selectors, or boilerplate.
- Use synthetic examples and reserved domains in tests, fixtures, configuration examples, and documentation.
- Name local and remote branches after the behavior they change, such as `fix/glossary-popovers`. Leave feed, publisher, and channel identifiers out of branch names.

## Preserve behavior-specific test coverage

- Keep coverage for each existing behavior and edge case when refactoring code, replacing an implementation, or updating fixtures. If a test needs to change, add equivalent assertions against the replacement code path in the same change. Use synthetic fixtures that preserve the conditions that trigger the behavior.
- Remove or revise a behavior-specific expectation only when the task explicitly changes or removes that behavior. Explain the change in the pull request.

## Protect scrolling and rendering performance

- Treat SwiftUI `body`, view-building helpers, layout/update methods, and scroll callbacks as frequently executed UI paths. Do not perform language detection, tokenization, hyphenation, HTML parsing, image decoding, synchronous I/O, or other expensive content preparation in these paths.
- Prepare immutable presentation data off the main actor and reuse it across view updates and scrolling. A `Task` created from UI code can inherit the main actor; verify where CPU work actually executes. Recompute only when relevant content or settings change, preserve source data, and prevent stale preparation results from replacing the current page.
- When changing rendering or scroll-related state, inspect the full update path for repeated work, allocations, and unnecessary invalidation. Add behavior-level regression coverage for preparation reuse and invalidation when those mechanisms change.
- For changes that can affect scrolling, compare before/after performance on a supported Apple runtime using a long synthetic article, representative languages, and media where relevant. Profile main-thread work and scrolling hitches on a device when available. Passing builds or content tests alone do not establish smooth scrolling; report unavailable performance validation explicitly and do not claim it passed.

## Check updates against existing decisions

- Before implementing any update, including a refactor, test change, or documentation edit, review [Product decisions](docs/product-decisions.md) and [Technical decisions](docs/technical-decisions.md). Identify which decisions the update affects and check its proposed behavior and implementation against them.
- If the update would change or contradict a recorded decision, ask the user before implementing that part. Cite the decision ID, describe the current contract and the proposed change, and wait for an explicit answer. Continue independent work that preserves the decisions.
- When the user approves a change, update the affected decision records, implementation, and relevant tests together as applicable. Record new durable decisions with their evidence. If evidence disagrees, surface the discrepancy and ask the user before choosing a different contract.
- Before finishing, review the actual diff against both records so incidental changes are caught as well.
