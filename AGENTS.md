# Repository instructions

## Keep the repository feed-agnostic

- Base article extraction, rendering, and media handling on shared formats, markup, and user-provided settings. Do not hard-code rules or defaults for individual feeds, publishers, or channels, including their domains, URLs, selectors, or boilerplate.
- Use synthetic examples and reserved domains in tests, fixtures, configuration examples, and documentation.
- Name local and remote branches after the behavior they change, such as `fix/glossary-popovers`. Leave feed, publisher, and channel identifiers out of branch names.

## Preserve behavior-specific test coverage

- Keep coverage for each existing behavior and edge case when refactoring code, replacing an implementation, or updating fixtures. If a test needs to change, add equivalent assertions against the replacement code path in the same change. Use synthetic fixtures that preserve the conditions that trigger the behavior.
- Remove or revise a behavior-specific expectation only when the task explicitly changes or removes that behavior. Explain the change in the pull request.
