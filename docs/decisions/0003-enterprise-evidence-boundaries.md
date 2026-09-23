# ADR-0003: Require explicit evidence for enterprise identity and API compatibility

- Status: Accepted
- Date: 2026-09-24

## Context

SchneeBar supports GitHub.com, GitHub Enterprise Cloud with data residency (GHE.com), and self-hosted GitHub Enterprise Server (GHES).

Enterprise deployments expose several signals that are easy to over-interpret:

- SAML/SSO authorization failures can appear alongside otherwise accessible installations.
- Enterprise Managed Users (EMU) have documented behavioral restrictions, but the ordinary authenticated-user REST schema does not currently document a normal-user boolean or enum that identifies the authenticated account as managed.
- GHES release versions and REST API versions are distinct. GitHub publishes versioned GHES OpenAPI descriptions, but the checked GHES 3.20-3.22 descriptions do not establish a public `GET /api/v3/versions` negotiation operation.

Guessing from usernames, hosts, repository visibility, generic 403/404 responses, or an undocumented endpoint would turn provider ambiguity into false product state.

## Decision

SchneeBar uses an explicit-evidence rule for enterprise classification.

### SAML / SSO

SchneeBar may surface SSO-required state only from normalized provider evidence that explicitly represents an SSO requirement.

Ordinary forbidden responses, empty repository sets, inaccessible installations, or GHE.com hosting are not SSO evidence.

Accessible installations may coexist with SSO-required installations; this is represented as partial access rather than collapsing the whole connection into a failure.

### Enterprise Managed Users

SchneeBar does not currently expose an explicit EMU / managed-user identity flag.

Do not infer EMU from:

- username format or suffix;
- email/domain;
- GitHub.com vs GHE.com host;
- repository visibility;
- ordinary 403/404 behavior;
- SAML/SSO-required evidence.

Do not request enterprise-owner or SCIM administration privileges only to classify an account.

Explicit EMU classification may be added only when GitHub documents a stable signal available to SchneeBar's normal GitHub App user-access-token path, or a reproducible enterprise fixture proves an equivalent non-admin signal.

### GHES REST API versions

Use only API-version combinations backed by authoritative GHES evidence.

Current supported compatibility evidence:

- GHES 3.20: `2022-11-28`
- GHES 3.21: `2022-11-28`, `2026-03-10`
- GHES 3.22: `2022-11-28`, `2026-03-10`

SchneeBar may choose its preferred supported version from that evidence-backed release matrix.

Do not add a runtime `/api/v3/versions` probe until the endpoint is documented for GHES in official API documentation/OpenAPI, or verified against a reproducible real GHES fixture with defined authentication, response schema, and absence behavior.

Unknown or untested GHES releases must not inherit the newest known API version by assumption.

## Consequences

Positive:

- enterprise UI state remains explainable from concrete provider evidence;
- no new enterprise-admin permission is required for normal connections;
- GitHub.com, GHE.com, and GHES behavior cannot be conflated through hostname heuristics;
- undocumented network probes do not become connection dependencies;
- future upstream evidence can be integrated behind existing provider boundaries.

Costs:

- SchneeBar cannot currently label an account as EMU even when a human administrator knows that it is managed;
- true runtime GHES API-version negotiation remains deferred;
- some enterprise states remain intentionally `unknown` rather than being guessed.

## Revisit when

Re-evaluate the EMU decision when GitHub publishes a stable normal-user/GitHub-App discriminator.

Re-evaluate GHES runtime negotiation when official GHES documentation/OpenAPI publishes a supported-version endpoint, or a reproducible GHES test fixture establishes its contract.
