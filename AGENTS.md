# Repository instructions

## Keep the repository feed-agnostic

- Base article extraction, rendering, and media handling on shared formats, markup, and user-provided settings. Do not hard-code rules or defaults for individual feeds, publishers, or channels, including their domains, URLs, selectors, or boilerplate.
- Use synthetic examples and reserved domains in tests, fixtures, configuration examples, and documentation.
- Name local and remote branches after the behavior they change, such as `fix/glossary-popovers`. Leave feed, publisher, and channel identifiers out of branch names.
