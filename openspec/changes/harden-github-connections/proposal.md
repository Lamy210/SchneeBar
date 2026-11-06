# Proposal: Harden local-first GitHub connections before companion integration

## Why

SchneeBar already supports multi-account GitHub Device Flow, Keychain credentials, refresh rotation and workflow mutations. Static review found security-hardening questions around macOS Data Protection Keychain selection, optional non-expiring token responses, unexpected HTTP redirects, read/write privilege separation and cleanup errors. The new Companion integration must not inherit or widen these risks.

## What changes

- Verify actual macOS Keychain accessibility and implement non-destructive legacy → Data Protection Keychain migration.
- Make newly issued user credentials expiry-aware with verified GitHub App behavior; preserve refresh race correctness.
- Reject unexpected redirects for secret-bearing authenticated/OAuth requests.
- Design a separate write-authorization boundary for optional workflow actions.
- Clearly distinguish local disconnect, partial local cleanup and remote GitHub authorization revocation.
- Protect against arbitrary preview Client ID consent confusion and prohibit local events from invoking GitHub mutations.

## In scope

Security design/tests and subsequent isolated implementation on the existing local-first architecture, including GitHub.com/GHE.com and evidence-backed GHES compatibility.

## Out of scope

A mandatory broker, Client Secret in app, remote password/2FA handling, full security certification, and immediate Companion rendering changes. ADR-0002 remains accepted.

## Prerequisites

Real Mac tests for Keychain behavior; mock HTTP/OAuth tests; no real GitHub credentials in fixtures.

## Completion criteria

Do not mark completed until tests demonstrate no secret-bearing cross-origin traffic, safe migration, zero unauthorized workflow writes, correct reconnect/rotation, and accurate disconnect state.
