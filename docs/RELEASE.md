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

The workflow requires that exact SHA to still be the dispatched `main` head, verifies the exact commit's push `CI` and `CodeQL` workflows are successful, reruns the full test suite, and renders the deterministic visual smoke before packaging.

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
