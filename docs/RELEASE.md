# Release Process

SchneeBar uses two release tiers.

## 1. Preview prerelease

Preview builds are intended for early testing while the project is still pre-release.

Current workflow:

- workflow: `.github/workflows/release-preview.yml`
- trigger: manual `workflow_dispatch` from `main` only
- tag format: `vMAJOR.MINOR.PATCH-PRERELEASE`
- first candidate: `v0.1.0-alpha.1`
- build configuration: `Release`
- artifact: `SchneeBar-<version>-unsigned.zip`
- architectures: universal `arm64 + x86_64`
- integrity: SHA-256 checksum + ad-hoc code signature
- GitHub Release state: prerelease
- Apple Developer ID signature: **no**
- Apple notarization: **no**

An ad-hoc signature verifies bundle integrity only. It does not establish Apple developer identity and does not satisfy Gatekeeper notarization requirements.

Do not publish a preview as a stable release.

The repository has not yet selected stable source/binary distribution terms. Preview release notes must point testers back to the repository's current license-status statement rather than implying an open-source or stable binary license. Stable terms are tracked separately in #215.

### Opening an unsigned preview

Because preview artifacts are not Developer ID signed or notarized, macOS Gatekeeper can block the first launch.

For a preview obtained from the official SchneeBar GitHub Release:

1. verify the downloaded ZIP against the attached SHA-256 file;
2. extract `SchneeBar.app`;
3. attempt to open the app normally;
4. if macOS blocks it and you have independently verified the release source/checksum, open **System Settings → Privacy & Security** and use **Open Anyway** for SchneeBar.

Do not disable Gatekeeper globally and do not instruct users to remove quarantine metadata as the normal installation path.

Apple guidance:
- https://support.apple.com/ja-jp/102445
- https://support.apple.com/ja-jp/guide/security/sec5599b66df/web

## 2. Stable release

A stable release must not use the unsigned preview workflow as-is.

Before the first stable release, add a protected release workflow/environment that performs:

1. Release build from an exact reviewed `main` commit.
2. Hardened Runtime enabled for the distributed app/executable targets with only required runtime exceptions.
3. Developer ID Application signing with a secure timestamp.
4. Signature and entitlement verification with `codesign --verify --deep --strict` plus explicit signature inspection.
5. Apple notarization with `notarytool`.
6. Notarization stapling and validation with `stapler`.
7. Gatekeeper assessment with `spctl --assess --type execute`.
8. Archive packaging after signing/notarization.
9. SHA-256 generation and verification.
10. GitHub Release creation from the exact tested commit.

Signing certificates, private keys, App Store Connect API credentials, and notarization credentials must exist only in the protected release environment. They must never be available to pull-request jobs.

### Stable release environment

The stable workflow uses a protected GitHub Actions environment named `release`. Configure approval/protection rules before enabling stable publication.

Required environment secrets:

- `APPLE_DEVELOPER_ID_P12_BASE64`: base64-encoded Developer ID Application certificate + private key in PKCS#12 form;
- `APPLE_DEVELOPER_ID_P12_PASSWORD`: PKCS#12 password;
- `APPLE_DEVELOPER_ID_APPLICATION`: exact `codesign` authority string, for example the full `Developer ID Application: ... (TEAMID)` identity;
- `APPLE_TEAM_ID`: Apple Developer Team ID;
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key ID;
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID;
- `APPLE_NOTARY_KEY_P8_BASE64`: base64-encoded App Store Connect private key.

Do not use repository-level secrets for these values when a protected release environment can scope them more narrowly.

The stable workflow is fail-closed and will not start publication unless:

- the exact reviewed `main` SHA still matches `expected_sha`;
- exact-SHA push CI and CodeQL are green;
- a root `LICENSE` or `DISTRIBUTION_TERMS.md` exists;
- `docs/RELEASE_ASSET_PROVENANCE.md` exists as the maintainer-reviewed record for distributed artwork/resources;
- all required Apple secrets are present;
- the Release app is universal `arm64 + x86_64`;
- no unexpected embedded runtime code is present in Frameworks, PlugIns, XPCServices, Helpers, LoginItems, or LaunchServices without updating the explicit stable audit;
- the Developer ID authority/team match the configured identity;
- Hardened Runtime is present and no unexpected entitlements are signed;
- notarization, stapling, Gatekeeper assessment, archive verification, and checksum verification all succeed;
- the notarized/stapled packaged app launches and remains alive on the official `macos-26-intel` x64 runner before stable publication.

Temporary PKCS#12/API-key files and the temporary signing keychain are deleted with an `always()` cleanup step.

## Versioning

Git tags use semantic versioning:

```text
v0.1.0-alpha.1
v0.1.0-beta.1
v0.1.0
```

The app bundle uses Apple's numeric marketing version:

```text
CFBundleShortVersionString = 0.1.0
CFBundleVersion = <GitHub Actions run number>
```

The prerelease suffix belongs to the Git tag / GitHub Release name, not to `CFBundleShortVersionString`.

## Preview release checklist

Before dispatching a preview release:

- `main` has no release-blocking open pull requests.
- Exact-head CI is green.
- Visual Regression is green.
- CodeQL is green.
- The real-app External Widget smoke test is green and not skipped.
- The selected commit is the intended release commit.
- `docs/DEVELOPMENT_PLAN.md` accurately reflects known deferred work.
- No credentials or private enterprise URLs are present in the repository or artifacts.

Then run **Release Preview** from the GitHub Actions UI on the `main` branch and provide:

- a prerelease tag such as `v0.1.0-alpha.1`;
- the full 40-character reviewed `main` commit SHA as `expected_sha`.

The workflow requires that exact SHA to still be the dispatched `main` head, verifies the exact commit's push `CI` and `CodeQL` workflows are successful, reruns the full test suite, and renders the deterministic visual smoke before packaging. Build/test/package runs with read-only repository permissions. The resulting ZIP, checksum, and release notes are transferred as a bounded Actions artifact to a separate checkout-free publish job; only that publish job receives `contents: write`, and it re-verifies payload shape, checksum, archive integrity, release tag, and embedded release SHA before creating the GitHub prerelease.

The workflow rejects:

- non-prerelease tag syntax;
- dispatch from a branch other than `main`;
- a tag that already exists;
- a non-40-character expected SHA;
- an expected SHA that does not match the dispatched `main` head;
- missing/failed exact-commit push CI or CodeQL;
- a missing release app;
- mismatched bundle version metadata;
- a missing arm64 or x86_64 executable slice;
- failed ad-hoc signature verification.

## Rollback

GitHub Releases are immutable release records for a specific tested commit. Do not silently replace a published archive under the same version.

If a preview is bad:

1. mark the release as superseded in its notes;
2. fix the issue on `main`;
3. publish a new prerelease tag, for example `v0.1.0-alpha.2`.

Do not reuse an existing tag for different bytes.
