# SchneeBar OpenSpec workflow

OpenSpec is the behavioral planning source for proposed features. The accepted architecture decisions remain in `docs/decisions/`. Proposed ADR-0004 does **not** supersede ADR-0002.

## Changes

- [`integrate-schneerunner`](changes/integrate-schneerunner/proposal.md): user-facing Character, Focus, integration and settings capabilities.
- [`harden-github-connections`](changes/harden-github-connections/proposal.md): GitHub credential, token/transport, authorization and security UX hardening.

These changes are **proposals**, not implemented functionality. Checkboxes in `tasks.md` are completion evidence; they must not be marked complete merely because specs exist.

## Local CLI usage

Use OpenSpec 1.16.0 or compatible CLI (Node.js 22.12.0+ is required for npm-distributed OpenSpec):

```bash
npm install -g @fission-ai/openspec@1.16.0
openspec status --change integrate-schneerunner
openspec status --change harden-github-connections
openspec validate integrate-schneerunner --strict --no-interactive
openspec validate harden-github-connections --strict --no-interactive
openspec validate --all --strict --no-interactive
```

The pinned Ubuntu workflow `.github/workflows/openspec.yml` runs the strict validation on PRs that modify `openspec/**` and on main updates. It uses read-only checkout, disables OpenSpec telemetry and has no application/release secrets.

## Process

1. Review `proposal.md`, delta specs, `design.md`, and task prerequisites before implementation.
2. For GitHub-connected Companion, complete relevant `harden-github-connections` security gates first; local-only CompanionCore development can proceed independently.
3. Implement under a dedicated PR with tests and measurable evidence, checking off only verified tasks.
4. Run strict validation and the native test/visual suites; perform real-Mac Keychain, notification and resource tests where specified.
5. Archive the change **only after** implementation and acceptance, allowing its delta specs to become canonical. Do not archive at the Phase 0 docs PR stage.

ADR-0001 and ADR-0002 remain accepted. Switching to a mandatory PKCE broker requires a separate security/design decision.
