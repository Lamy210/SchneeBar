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

When present it must be finite and between the Unix epoch and 2100-01-01 UTC.
The timestamp affects snapshot diagnostics only; it does not grant scheduling,
execution, or network capabilities.

### Collections

Duplicate widget IDs fail the entire collection.

A successfully normalized collection is sorted by canonical widget ID so load
order is deterministic.

## Module boundary

`SchneeBarExternalWidgets` owns the external document and normalization rules.

It depends on `SchneeBarCore` and produces existing Core models. Core and
`WidgetEngine` do not depend on external document types.

Filesystem loading, symlink/path rules, atomic writes, signing, and third-party
installation UX are intentionally deferred to separate, threat-modeled slices.
