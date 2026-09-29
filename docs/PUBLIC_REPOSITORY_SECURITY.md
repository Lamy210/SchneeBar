# Public Repository Security

SchneeBar is public. Pull-request code from forks must be treated as untrusted.

## CI invariants

- Default workflow permissions are `contents: read`.
- PR workflows do not receive release/signing/GitHub application secrets.
- Do not run untrusted PR code from a privileged `pull_request_target` workflow.
- Checkout credentials are not persisted into the working copy.
- The mise setup action does not expose the automatic `GITHUB_TOKEN` to later build/test steps.
- PR jobs do not save shared tool caches.
- Actions are pinned to full immutable commit SHAs, with version comments for reviewability.
- Dependabot tracks Action updates.
- Release signing/notarization must live in a separate protected workflow/environment.
- Stable Developer ID PKCS#12 material, signing passwords, App Store Connect API private keys, key IDs, issuer IDs, and Apple Team identity values must be scoped to the protected `release` environment and never referenced by pull-request jobs.
- Stable repository checkout, tests, visual smoke, and Release build run in a separate secret-free job. The protected signing/notarization job downloads only a bounded checksummed unsigned app artifact; it does not checkout the repository, run Tuist, execute tests, or launch repository-built code before Apple credentials are used.
- Stable signing-input and release ZIPs are capped at 512 MiB compressed, 1 GiB uncompressed, and 10,000 entries and are revalidated at downstream trust boundaries; signing-input archive paths are checked before extraction and may only target the `SchneeBar.app` root.
- Stable signing uses an ephemeral keychain; decoded PKCS#12/API-key files and that keychain must be removed on success or failure.
- The manual preview-release workflow splits read-only build/package work from publication: repository code is built/tested only with `actions: read` + `contents: read`; `contents: write` exists only in a checkout-free publish job that verifies and uploads the bounded release payload. It must not receive Apple signing/notarization secrets.
- Release publication must bind to an explicit full expected commit SHA and refuse a moving/unreviewed `main` head.

## CodeQL merge gate

Swift CodeQL is intentionally deferred while a pull request is in Draft so normal development pushes do not repeatedly occupy a macOS runner with an expensive extraction build.

- Draft pull requests create a CodeQL workflow run whose analysis job is skipped.
- Marking a pull request Ready for review starts a real CodeQL analysis for the current head.
- Synchronizing a non-Draft pull request runs CodeQL again for the new head.
- Converting a pull request back to Draft creates a skipped run and allows the workflow concurrency policy to supersede analysis for the previous review state.
- Pushes to `main` and the scheduled scan continue to run CodeQL normally.
- A skipped Draft CodeQL result is **not** approval to merge. The final pull-request head must have a successful non-Draft CodeQL analysis before merge.

Repository rules should require the stabilized CodeQL check together with normal CI once branch/ruleset protection is enabled.

## Application secrets

Never commit or embed:

- GitHub access/refresh tokens
- GitHub App client secret as if it could remain secret in a public binary
- GitHub App private keys
- Apple Developer signing material
- notarization passwords/API private keys
- customer GHES credentials

User tokens belong in Keychain. A future server-side GitHub App private key belongs only in server secret storage.

## Enterprise fixtures

Tests must use fictional hosts and sanitized fixtures. Never copy real customer/employer repository names, internal URLs, tokens, SSO identifiers, or response payloads without sanitization.

## Supply chain

- Pin CI actions by SHA.
- Pin developer tools (`.mise.toml`) and CI's mise bootstrap version.
- Keep third-party runtime dependencies minimal.
- Review dependency permission/network behavior before addition.
- Use Dependabot and CodeQL.
- Preview toolchains run in a non-blocking canary and never receive release credentials.

## Repository settings to enable manually

The repository owner should enable, when available:

- Private Vulnerability Reporting
- secret scanning / push protection
- branch/ruleset protection on `main`
- required CI checks after their names have stabilized
- deletion protection / review requirements appropriate for the maintainer model

These are GitHub repository settings and are intentionally not encoded as secrets or privileged automation in normal PR workflows.
