# P0 follow-up: reject unsafe initial GitHub credential request URLs

## Context
The GitHub HTTP transport already uses a no-redirect task delegate, rejects 300–399 responses and refuses persistent URLSession state for OAuth and bearer requests. Those measures do **not** inspect the initial URL selected by the caller. If a future call accidentally constructs an HTTP URL or URL with embedded userinfo, the existing no-redirect protection does not stop that initial request. No exploitation or real credential disclosure was reproduced.

## Contract
- Before executing `URLSession.data(for:delegate:)`, validate the original `URLRequest.url` with URLComponents: HTTPS scheme, nonempty host, no URL username/password, no fragment, and valid optional port (1–65535). If invalid, throw `GitHubHTTPTransportError.unsafeRequestURL` with **zero network requests**.
- Preserve support for HTTPS on nonstandard ports (GHES deployments); do not require a fixed GitHub.com hostname at this transport layer. The caller-specific endpoint resolver remains responsible for binding API hosts to a previously authenticated account.
- Preserve per-task redirect rejection, fail-closed 300–399 response handling, session configuration constraints and existing OAuth token validation. No logs or diagnostics may include credentials or URL-embedded secrets.
- The new request gate is **not** sufficient to prove a request's HTTPS host is authorized for any given bearer token. Existing endpoint and account binding still apply.

## Deterministic tests
- Using a URLProtocol-only synthetic session, a request with a bearer placeholder to `http://`, HTTPS with username/password, HTTPS with fragment or invalid port 0 returns `unsafeRequestURL`, not a redirect or success result. No external network is performed.
- A well-formed HTTPS request on GHES-like nonstandard port 8443 passes the initial gate and is subsequently rejected because the synthetic response is a 302. This ensures redirect safety is retained.
- Existing token, URLSession configuration, GitHub.com/GHE.com/GHES endpoint and user-identity tests remain green.

## Merge gate
- macOS CI Build/Test with both new tests, Visual Regression, OpenSpec strict and zero unresolved review threads on the exact HEAD; do not merge while any are queued or failed.
- This is a narrowly scoped defense-in-depth change for P0 #369, not confirmation that the current version leaks secrets. Signed real-Mac credential tests and provider identity verification remain release gates.
