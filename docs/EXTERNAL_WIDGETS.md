# Declarative External Widgets

SchneeBar's first external-widget contract is deliberately data-only.

It defines a versioned document that can be validated and normalized into the
existing provider-neutral `WidgetDescriptor` and `WidgetSnapshot` models.
It does not add another widget runtime and does not change `WidgetEngine`.

## Security boundary

Version 1 does **not** support:

- shell commands or scripts;
- JavaScript, Wasm, native bundles, or dynamic libraries;
- network URLs or HTTP polling;
- credential, secret, token, or Keychain references;
- filesystem paths or file watching;
- installation or marketplace metadata.

Unknown JSON keys fail decoding instead of being silently ignored. This keeps a
newer or capability-bearing document from being accidentally accepted by an
older SchneeBar build.

## Version 1 example

```json
{
  "schemaVersion": 1,
  "id": "external.acme.build",
  "displayName": "Acme Build",
  "defaultEnabled": false,
  "defaultOrder": 1200,
  "defaultRepresentation": "normal",
  "visibility": {
    "kind": "minimumSeverity",
    "minimumSeverity": "attention"
  },
  "refresh": {
    "kind": "adaptive",
    "activeSeconds": 15,
    "idleSeconds": 300
  },
  "snapshot": {
    "severity": "attention",
    "priority": "attention",
    "compact": {
      "text": "!1",
      "systemImage": "exclamationmark.triangle.fill",
      "accessibilityLabel": "One build needs attention"
    },
    "normal": {
      "text": "Build needs attention",
      "systemImage": "hammer",
      "accessibilityLabel": "Acme build needs attention"
    }
  }
}
```

## Validation policy

### Schema

Only `schemaVersion: 1` is accepted.

Unknown enum values and unknown keys fail closed.

### Widget ID

IDs are reserved under `external.`.

The full ID is limited to 96 UTF-8 bytes. Each component after `external` must
be non-empty and contain only lowercase ASCII letters, digits, or underscore.

Examples:

- valid: `external.acme.build`
- valid: `external.team_1.deploy`
- invalid: `system.cpu`
- invalid: `external.Acme.build`
- invalid: `external.acme-build`
- invalid: `external..build`

### Default behavior

External documents cannot self-enable. `defaultEnabled` must be `false`.

The default order must be between 1000 and 10000 so native widgets retain the
front of the default ordering. Users can still reorder an enabled widget through
the normal SchneeBar preference model later.

The default representation may be `compact` or `normal`. External documents
cannot default themselves to `critical`; a user may still choose a supported
representation through SchneeBar preferences.

### Refresh policy

Allowed policies are:

- `manual`;
- `interval`, from 5 through 3600 seconds;
- `adaptive`, with both active and idle intervals in that same range and
  `activeSeconds <= idleSeconds`.

Version 1 merely describes the existing Core refresh policy. This document
contract does not provide a loader or a source of changing data.

### Content

Compact text is limited to 32 characters / 128 UTF-8 bytes.

Normal and critical text are limited to 128 characters / 512 UTF-8 bytes.

Accessibility labels are limited to 160 characters / 640 UTF-8 bytes.

Strings are trimmed and must remain non-empty. Control characters are rejected.

Version 1 supports only this SF Symbol allowlist:

- `antenna.radiowaves.left.and.right`
- `bolt.fill`
- `checkmark.circle`
- `checkmark.circle.fill`
- `clock`
- `cpu`
- `exclamationmark.triangle`
- `exclamationmark.triangle.fill`
- `externaldrive.fill`
- `hammer`
- `info.circle`
- `memorychip`
- `network`
- `questionmark.circle`
- `server.rack`
- `xmark.circle`
- `xmark.circle.fill`

The image may also be omitted.

### Generated timestamp

`generatedAtUnixSeconds` is optional. The example intentionally omits it so a
copied static document does not become invalid merely because its example
timestamp is in the future. When absent, normalization uses its injected current
time.

When present it must be finite, between the Unix epoch and 2100-01-01 UTC, and
no more than five minutes ahead of the normalization clock. This prevents an
external document from manufacturing implausibly fresh diagnostic timestamps.

The timestamp affects snapshot diagnostics only; it does not grant scheduling,
execution, or network capabilities.

### Collections

Duplicate widget IDs fail the entire collection.

A successfully normalized collection is sorted by canonical widget ID so load
order is deterministic.

## Read-only Application Support loader

The first filesystem adapter reads direct-child `.json` documents from:

`~/Library/Application Support/SchneeBar/ExternalWidgets`

The loader is read-only. It does not create the directory, watch it, install
documents, or mutate `WidgetEngine`.

Safety policy:

- a missing SchneeBar owner directory or `ExternalWidgets` directory is an empty collection;
- the trusted Application Support anchor is opened as a directory without following its final component;
- the app-owned `SchneeBar` and `ExternalWidgets` path components are opened step-by-step with `openat(..., O_DIRECTORY | O_NOFOLLOW)`, so a symlinked app-owned parent or root is rejected;
- directory entries are enumerated from a duplicated descriptor for the already-open root, not by resolving the path again;
- child files are opened with `openat(..., O_NOFOLLOW | O_NONBLOCK)`;
- only direct-child, case-sensitive `.json` filenames are considered;
- symbolic links, hard links, and non-regular `.json` entries fail closed;
- JSON filenames are limited to 255 UTF-8 bytes and control characters are rejected before opening;
- fd-based enumeration stops and fails closed after 256 direct directory entries, including non-JSON entries;
- at most 32 JSON documents are accepted;
- each document is limited to 64 KiB;
- aggregate JSON input is limited to 512 KiB;
- reads are bounded even if a file grows after metadata inspection;
- cancellation is checked before filesystem work, between documents, during bounded reads, and before normalization;
- all documents are decoded and normalized before a collection is returned;
- duplicate IDs or any decode/validation failure reject the whole collection;
- loader errors do not retain raw file contents, filesystem paths, filenames, provider strings, or rejected document values.

The production initializer always uses the dedicated SchneeBar Application
Support directory. A custom root exists only as an internal test seam.

File watching, automatic registration, installation UI, signing/trust, and any
execution/network capability remain separate concerns.

## Startup registration

SchneeBar loads the bounded Application Support collection once during widget
runtime startup. Only a fully validated collection is handed to
`WidgetEngine`, where the dedicated `external.widgets` provider group is
replaced atomically.

Startup-only v1 providers intentionally use `manual` runtime refresh even when
the declarative document contains a bounded interval/adaptive refresh policy.
That metadata is retained by the document contract for a future live source
adapter, but this slice does not poll the filesystem merely to satisfy it.

Consequences:

- a new external widget remains disabled unless an existing persisted
  `WidgetPreference` explicitly enables its stable ID;
- preferences are keyed independently of provider presence, so a temporarily
  missing widget can regain the same explicit preference when its stable ID
  returns on a later launch;
- removed documents disappear only after a successful full collection load;
- loader/validation failure leaves the previous provider group untouched;
- startup cancellation does not intentionally apply a replacement after the
  cancellation boundary;
- native/unrelated provider IDs cannot be replaced by the external group;
- no directory watcher or periodic filesystem polling is introduced.

## Startup health diagnostics

Startup registration exposes only a sanitized App-level health state:

- `notAttempted`;
- `loading`;
- `loaded(widgetCount)`;
- `unavailable(reason)`.

Unavailable reasons are coarse and stable: unsafe storage, resource limit,
invalid documents, unreadable storage, registration conflict, or unknown.

The diagnostic state never retains:

- filesystem paths or filenames;
- raw JSON or decoding payloads;
- widget IDs, display names, provider strings, or rejected values;
- the original loader or registration error.

Cancellation propagates instead of becoming `unavailable`. Runtime generation
checks reject terminal results from startup work invalidated by sleep/wake. When
sleep interrupts unfinished startup work, visible health returns to
`notAttempted` so a wake retry cannot leave a stale `loading` state.

Startup health changes no registration semantics: it does not enable widgets,
retry the loader, watch the filesystem, perform network requests, or add
filesystem reads.

The App-layer `ExternalWidgetStartupCoordinator` owns the one-shot startup
attempt state, cancellation boundary, stale-completion rejection, and sleep
retry semantics. `MenuBarController` remains responsible for the broader
runtime generation and refresh loop and only supplies the current-generation
predicate to the coordinator. This keeps the startup contract testable without
constructing AppKit status-bar UI.

### Manual real-launch smoke check

Before release candidates that change this startup path, validate the same
startup-only behavior in the built app:

1. Quit SchneeBar completely.
2. Place one valid v1 JSON document directly in
   `~/Library/Application Support/SchneeBar/ExternalWidgets`.
3. Launch SchneeBar.
4. Open Settings and confirm External Widgets reports `Loaded` with a count of
   one.
5. Confirm the external widget is still disabled until explicitly enabled in
   widget preferences.
6. Relaunch and confirm the same stable widget ID keeps its explicit
   preference.
7. Remove the document, relaunch, and confirm startup completes with zero
   external widgets rather than retaining the removed provider.
8. Separately use a malformed document and confirm Settings exposes only the
   coarse invalid-document health state, never its filename, path, JSON, or
   rejected value.

This is a release smoke check, not a live-reload contract. Editing files while
SchneeBar is running is intentionally outside v1 behavior.

### Settings presentation

Settings renders only the sanitized startup-health presentation derived from
the App-level enum:

- not checked;
- loading;
- loaded, with the normalized widget count only;
- unavailable, with one coarse reason sentence.

Settings does not receive or render filesystem paths, filenames, raw JSON,
widget/provider identifiers, rejected field values, or original error text.

## Module boundary

`SchneeBarExternalWidgets` owns the external document and normalization rules.

It depends on `SchneeBarCore` and produces existing Core models. Core and
`WidgetEngine` do not depend on external document types.

File watching/live reload, atomic-write install flows, signing, and third-party
installation UX are intentionally deferred to separate, threat-modeled slices.
