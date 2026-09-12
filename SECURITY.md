# Security Policy

SchneeBar is a public macOS project that will eventually handle GitHub authentication material and developer metadata. Security reports should therefore avoid public disclosure of exploitable details.

## Reporting a vulnerability

Prefer GitHub **Private Vulnerability Reporting** for this repository when it is enabled.

Do **not** publish access tokens, refresh tokens, GitHub App secrets, private enterprise hostnames, exploit payloads, or other sensitive evidence in a public issue.

If private vulnerability reporting is not yet enabled, open a minimal public issue stating only that you need a private security contact; do not include technical exploit details.

## Supported versions

The project is pre-release. Security fixes currently target the latest `main` branch.

## Security invariants

- Secrets belong in macOS Keychain, never source control or SQLite plaintext.
- GitHub read-only permissions are the default.
- GitHub write permissions require explicit feature-level opt-in.
- A GitHub App private key must never be embedded in the public desktop binary.
- TLS certificate validation must not be bypassed for self-hosted GitHub Enterprise Server.
- Pull-request workflows must be safe for untrusted forks.
- Release/signing/notarization credentials must not be available to ordinary PR workflows.
