# Declarative External Widgets

## Status

The first external-widget contract is **data-only**.

This layer validates and normalizes a versioned document into SchneeBar's existing provider-neutral `WidgetDescriptor` and `WidgetSnapshot` models.

It does not load files, watch directories, execute programs, evaluate code, perform network requests, or access credentials.

## Security boundary

An external widget document cannot contain or request:

- shell commands or scripts;
- native bundle/dylib paths;
- JavaScript or Wasm;
- URLs to fetch;
- credentials, tokens, or secret references;
- arbitrary filesystem paths.

External widgets are normalized with `defaultIsEnabled = false`. A user must explicitly enable a future loaded external widget through normal widget preferences.

The external default order range is reserved after built-in widgets. User preferences may still reorder an enabled widget.

## Version 1 document

Example:

```json
{
  "schemaVersion": 1,
  "id": "external.build_status",
  "displayName": "Build Status",
  "defaultOrder": 1000,
  "defaultRepresentation": "normal",
  "visibility": "whenNotNominal",
  "refresh": {
    "kind": "interval",
    "intervalSeconds": 60
  },
  "snapshot": {
    "generatedAtEpochSeconds": 1790208000,
    "severity": "attention",
    "priority": "attention",
    "compact": {
      "text": "!1",
      "systemImage": "exclamationmark.triangle",
      "accessibilityLabel": "Build needs attention"
    },
    "normal": {
      "text": "Build needs attention",
      "systemImage": "exclamationmark.triangle",
      "accessibilityLabel": "Build needs attention"
    },
    "critical": {
      "text": "Build alert",
      "systemImage": "exclamationmark.triangle.fill",
      "accessibilityLabel": "Build alert"
    }
  }
}
```

## Validation

Version 1 currently requires:

- `schemaVersion == 1`;
- IDs in the canonical `external.*` namespace;
- an ID length of at most 128 characters;
- lowercase ASCII identifier characters only;
- a non-empty display name of at most 80 characters;
- default order from 1000 through 10000;
- default representation of `compact` or `normal`, never `critical`;
- visibility of `always` or `whenNotNominal`;
- refresh of either:
  - `manual`, with no interval value; or
  - `interval`, from 5 seconds through 24 hours;
- bounded single-line content/accessibility strings;
- system images from the adapter's explicit allowlist;
- finite non-negative generated-at epoch seconds, with at most five minutes of future clock skew.

Collections reject duplicate normalized widget IDs and return definitions in stable ID order.

## Runtime integration

The normalizer produces the same `WidgetDescriptor` and `WidgetSnapshot` types used by built-in widgets.

`WidgetEngine` remains unaware of external document types. This preserves existing:

- registration/replacement semantics;
- refresh scheduling;
- user enable/order/representation preferences;
- last-known-good snapshots;
- provider-neutral runtime diagnostics.

## Deferred I/O

A follow-up may define a loader for a dedicated Application Support directory.

That work must specify:

- ownership and directory permissions;
- regular-file and symlink policy;
- maximum document/file counts and total bytes;
- atomic-write behavior;
- reload/change notification strategy;
- malformed-file isolation;
- duplicate-file/widget-ID behavior;
- uninstall/removal cleanup.

No command execution or network capability is implied by this document format.
