# GitHub Integration

## Scope

SchneeBar treats GitHub as a Developer Activity provider rather than building a full GitHub client.

Primary surfaces:

- Actions workflow runs/jobs
- Pull requests and review requests
- Checks
- deployments/releases
- optional security widgets
- small, explicit opt-in actions later

## Connection types

The model must support multiple simultaneous connections:

1. GitHub.com / normal Enterprise Cloud on github.com
2. GHE.com / Enterprise Cloud with data residency
3. self-hosted GitHub Enterprise Server (GHES)

No production code should assume `api.github.com` globally.

A connection owns at minimum:

- web base URL
- REST base URL
- GraphQL URL
- auth base URL
- GitHub App client ID where applicable
- identity/installations
- server/API version metadata
- capability set
- permission set
- rate-limit budget
- last successful sync

## Authentication direction

For the local-first public desktop client, the initial preferred GitHub.com flow is GitHub App Device Flow because a public native binary cannot safely retain a client secret.

Tokens are stored in macOS Keychain. A GitHub App private key is never shipped in the desktop client.

If a future Auth/Webhook Relay is introduced, it is optional and separately threat-modeled.

## Permissions

Default is read-only and least-privilege. Permission escalation happens when the user enables the related feature, not at first launch.

Examples:

- Actions read for workflows/jobs
- Pull requests read for PR/review information
- Checks read when Check Runs are included
- Deployments read for deployment widgets
- Actions write only when workflow controls are explicitly enabled

## Enterprise

GHES support requires per-instance app registration; a GitHub.com App cannot simply be installed into a customer GHES instance.

Connection setup detects provider/server evidence conservatively and exposes only states justified by that evidence.

Enterprise evidence rules:

- SSO-required state comes only from explicit normalized SSO evidence; generic 403/404 responses, empty resources, and deployment host are not enough.
- Partial access is preserved when accessible installations coexist with explicit SSO-required installations.
- EMU is not inferred from usernames, domains, GHE.com hosting, repository visibility, or generic access failures. No enterprise-admin/SCIM permission is requested solely to classify account type.
- GHES REST API versions use the evidence-backed release compatibility matrix. Unknown/untested releases do not inherit the newest version by assumption.
- SchneeBar does not probe an undocumented GHES `/api/v3/versions` endpoint. Runtime negotiation requires an authoritative endpoint contract or reproducible GHES fixture first.

Connection health may still expose operational states such as SSO required, VPN/private-network unavailable, permission missing, untested server version, and rate limiting when the underlying provider evidence supports them.

TLS verification is mandatory. SchneeBar will not provide an 'ignore certificate errors' switch.

See [ADR-0003: Enterprise evidence boundaries](decisions/0003-enterprise-evidence-boundaries.md).
