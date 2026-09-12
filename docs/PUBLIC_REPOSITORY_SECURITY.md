# Public Repository Security

SchneeBar is public. Pull-request code from forks must be treated as untrusted.

## CI invariants

- Default workflow permissions are `contents: read`.
- PR workflows do not receive release/signing/GitHub application secrets.
- Do not run untrusted PR code from a privileged `pull_request_target` workflow.
- Actions are pinned to full immutable commit SHAs, with version comments for reviewability.
- Dependabot tracks Action updates.
- Release signing/notarization must live in a separate protected workflow/environment.

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
- Pin developer tools (`.mise.toml`).
- Keep third-party runtime dependencies minimal.
- Review dependency permission/network behavior before addition.
- Use Dependabot and CodeQL.

## Repository settings to enable manually

The repository owner should enable, when available:

- Private Vulnerability Reporting
- secret scanning / push protection
- branch/ruleset protection on `main`
- required CI checks after their names have stabilized
- deletion protection / review requirements appropriate for the maintainer model

These are GitHub repository settings and are intentionally not encoded as secrets or privileged automation in normal PR workflows.
