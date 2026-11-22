# P0 follow-up: reject credential-unsafe injected URLSessions

## Observed implementation gap
`URLSessionGitHubHTTPTransport` defaults to an ephemeral configuration without HTTP cookies, a URL cache or a URL credential store, but accepts an arbitrary **injected foreground URLSession** without checking those properties. Even with redirect refusal, storage of HTTP credentials/cookies or cached responses must not be silently re-enabled in the credential-bearing transport.

This is a defense-in-depth improvement. There is **no demonstrated credential leak or security exploit** from the preexisting code, and no change to production request destinations or OAuth scopes.

## Required invariant
- Before any request is sent through `URLSessionGitHubHTTPTransport.data(for:)`, reject background sessions (existing rule) and also reject foreground configurations with `httpShouldSetCookies == true`, or nonnil `httpCookieStorage`, `urlCredentialStorage` or `urlCache`.
- Preserve the existing `URLSessionGitHubHTTPTransport.defaultConfiguration()`, no-redirect callback, 30x hard-failure policy and `GitHubHTTPTransport` protocol.
- Return a typed `GitHubHTTPTransportError.unsafeSessionConfiguration`; no token or request body is logged, no persistent state is changed, and no network I/O happens on the rejection path.
- Reject each unsafe storage condition independently; an injected configuration matching the app's safe default should still be usable.
- The protections cover GitHub API and OAuth/Device Flow requests through this transport. They do not cover arbitrary network libraries bypassing this boundary.

## Tests and rollout gates
- Pure policy tests for cookies enabled, cookie storage, URL credential storage and URL cache, plus the normal safe configuration.
- Deterministic synthetic URLProtocol test: a persistent injected session fails specifically as `unsafeSessionConfiguration`.
- macOS Build/Test, Visual Regression, CodeQL (if not skipped) and OpenSpec strict validation on the exact PR head.
- Merge to `main` only after checks pass. Issue #369's separate hosted expiring-token, GHES compatibility, refresh rotation and real-Mac acceptance gates remain unresolved until their own verification.
