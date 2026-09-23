# ADR 0003: Do Not Infer Enterprise Managed User Classification

- Status: Accepted
- Date: 2026-09-24

## Context

SchneeBar supports GitHub.com and GHE.com connections and needs to explain
enterprise-specific access restrictions without misclassifying accounts.

GitHub documents Enterprise Managed Users (EMU) as accounts whose lifecycle and
authentication are managed by an enterprise identity provider. EMU is available
on both GitHub.com and GHE.com.

For SchneeBar's normal GitHub App user-access-token path, the current public
authenticated-user REST schema does not expose a documented EMU boolean or enum.
The public GraphQL `viewer: User!` / `User` schema likewise does not expose a
documented managed-user discriminator.

GitHub documents authorization-dependent visibility behavior for managed users,
including cases where a user lookup can return 404 to a caller that cannot view
that account. That behavior is not an identity signal: ordinary authorization
and visibility rules can produce the same observable result.

Enterprise identity-provider and external-identity APIs require elevated
organization or enterprise administration context. Requiring those permissions
only to label a normal SchneeBar connection would violate least privilege.

## Decision

SchneeBar will not explicitly classify an authenticated account as an
Enterprise Managed User unless GitHub provides a stable, documented signal that
is available to the normal non-admin GitHub App user-access-token path.

In particular, SchneeBar must not infer EMU from:

- username patterns or enterprise-generated suffixes;
- GitHub.com versus GHE.com hosting;
- repository or organization visibility;
- empty installation/repository inventories;
- HTTP 403 or 404 responses;
- SAML/SSO-required state;
- profile fields that are not documented as EMU identity evidence.

Observable restrictions remain modeled independently through existing
capability, authorization, network, and SSO evidence.

## Consequences

- No additional REST or GraphQL request is added for EMU detection.
- No enterprise-owner/admin permission is requested for account classification.
- GitHub.com and GHE.com keep the same conservative account-identity model.
- SchneeBar can still explain confirmed SSO or capability restrictions without
  claiming the account is an EMU.
- If GitHub later documents a suitable non-admin signal, EMU classification can
  be added in the provider layer and normalized before reaching generic UI
  state.

## Reconsideration criteria

Revisit this decision only when at least one of these is available:

1. an official REST field for the authenticated user that unambiguously
   identifies managed-user status;
2. an official GraphQL field available to ordinary authenticated users without
   enterprise-admin permissions; or
3. an authoritative reproducible fixture plus GitHub documentation establishing
   a stable equivalent signal.

A future implementation must cover GitHub.com and GHE.com separately and must
not add per-feature polling requests.

## References

- https://docs.github.com/en/enterprise-cloud@latest/admin/concepts/identity-and-access-management/enterprise-managed-users
- https://docs.github.com/en/enterprise-cloud@latest/rest/users/users
- https://docs.github.com/en/graphql/reference/users
- https://docs.github.com/en/graphql/reference/enterprise-admin
- https://github.com/Lamy210/SchneeBar/issues/81
