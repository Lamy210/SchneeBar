# Contributing

Thanks for your interest in SchneeBar.

## Current bootstrap policy

The repository is public, but a source-code license has not yet been selected. Until the maintainer explicitly chooses and commits a license, please use issues/design discussions for feedback and proposals; external code contributions may be deferred to avoid ambiguous copyright/licensing expectations.

## Development

```bash
mise install
mise exec -- tuist generate
mise exec -- tuist build
mise exec -- tuist test
```

For UI work, also run:

```bash
mise exec -- tuist run SchneeBarVisualHarness
```

## Architectural rules

- Domain/Application code must not depend on SwiftUI/AppKit.
- GitHub REST/GraphQL DTOs must be normalized before reaching UI state.
- New provider-specific behavior goes behind a port/adapter boundary.
- Prefer Swift Concurrency (`async/await`, actors, `AsyncSequence`) over new callback/GCD abstractions.
- Do not create generic `Utils` dumping grounds.
- UI states need deterministic fixtures when practical so Visual CI can cover them.

## Public repository rules

Never commit:

- access or refresh tokens
- OAuth/GitHub App secrets
- GitHub App private keys
- Apple signing certificates or passwords
- notarization credentials
- private GHES URLs copied from a real employer/customer environment
- `.env` files containing credentials

GitHub Actions added by contributors must use least-privilege permissions and immutable action SHAs.
