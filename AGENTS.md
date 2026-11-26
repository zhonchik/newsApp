# Repository instructions

## Keep the repository feed-agnostic

- Base article extraction, rendering, and media handling on shared formats, markup, and user-provided settings. Do not hard-code rules or defaults for individual feeds, publishers, or channels, including their domains, URLs, selectors, or boilerplate.
- Use synthetic examples and reserved domains in tests, fixtures, configuration examples, and documentation.
- Name local and remote branches after the behavior they change, such as `fix/glossary-popovers`. Leave feed, publisher, and channel identifiers out of branch names.

## Preserve behavior-specific test coverage

- Keep coverage for each existing behavior and edge case when refactoring code, replacing an implementation, or updating fixtures. If a test needs to change, add equivalent assertions against the replacement code path in the same change. Use synthetic fixtures that preserve the conditions that trigger the behavior.
- Remove or revise a behavior-specific expectation only when the task explicitly changes or removes that behavior. Explain the change in the pull request.

## Check updates against existing decisions

- Before implementing any update, including a refactor, test change, or documentation edit, review [Product decisions](docs/product-decisions.md) and [Technical decisions](docs/technical-decisions.md). Identify which decisions the update affects and check its proposed behavior and implementation against them.
- If the update would change or contradict a recorded decision, ask the user before implementing that part. Cite the decision ID, describe the current contract and the proposed change, and wait for an explicit answer. Continue independent work that preserves the decisions.
- When the user approves a change, update the affected decision records, implementation, and relevant tests together as applicable. Record new durable decisions with their evidence. If evidence disagrees, surface the discrepancy and ask the user before choosing a different contract.
- Before finishing, review the actual diff against both records so incidental changes are caught as well.
