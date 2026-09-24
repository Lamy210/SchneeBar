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
    "generatedAtUnixSeconds": 1800000000,
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

`generatedAtUnixSeconds` is optional. When absent, normalization uses its
injected current time.

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

- a missing directory is an empty collection;
- the root is opened with `O_DIRECTORY | O_NOFOLLOW`;
- directory entries are enumerated from a duplicated descriptor for that
  already-open root, not by resolving the path again;
- child files are opened with `openat(..., O_NOFOLLOW | O_NONBLOCK)`;
- only direct-child, case-sensitive `.json` filenames are considered;
- symbolic links, hard links, and non-regular `.json` entries fail closed;
- filenames are limited to 255 UTF-8 bytes and control characters are rejected;
- fd-based enumeration stops and fails closed after 256 direct directory entries, including non-JSON entries;
- at most 32 JSON documents are accepted;
- each document is limited to 64 KiB;
- aggregate JSON input is limited to 512 KiB;
- reads are bounded even if a file grows after metadata inspection;
- cancellation is checked before filesystem work, between documents, during
  bounded reads, and before normalization;
- all documents are decoded and normalized before a collection is returned;
- duplicate IDs or any decode/validation failure reject the whole collection;
- loader errors do not retain raw file contents, filesystem paths, filenames,
  provider strings, or rejected document values.

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
- removed documents disappear only after a successful full collection load;
- loader/validation failure leaves the previous provider group untouched;
- startup cancellation does not intentionally apply a replacement after the
  cancellation boundary;
- no directory watcher or periodic filesystem polling is introduced.

## Module boundary

`SchneeBarExternalWidgets` owns the external document and normalization rules.

It depends on `SchneeBarCore` and produces existing Core models. Core and
`WidgetEngine` do not depend on external document types.

File watching, automatic registration/replacement, atomic-write install flows,
signing, and third-party installation UX are intentionally deferred to
separate, threat-modeled slices.
