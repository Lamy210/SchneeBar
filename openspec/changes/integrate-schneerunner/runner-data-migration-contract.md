# Contract: Non-destructive SchneeRunner → SchneeBar data migration

Status: Proposed; does not automatically reach into the old app's sandbox or change currently installed apps.

## Source inventory and permission boundary

SchneeRunner stores productivity state and history as `Application Support/SchneeRunner/Productivity/state.json` and `history.json`. Character owned copies and package libraries are also in the Runner-owned Application Support tree.

**Not all settings are files**. `CharacterSelectionStore` reads/writes `SchneeRunner.lastSelectedCharacterID` in `UserDefaults.standard`; `DesktopCharacterVisibilityStore` uses `SchneeRunner.desktopCharacterVisible`. Additional Runner preference stores (desktop position/click-through, Pomodoro preferences, character reactions, last choices, Launch at Login, etc.) must be inventoried from source before declaring complete migration coverage. Never infer that reading SchneeBar's `UserDefaults.standard` returns the Runner domain.

Import order and access:
1. Identify the exact Runner app bundle ID, storage domain and optional sandbox/app-group restrictions using the actual installed build. Preserve source app's bundle ID as migration metadata.
2. For non-sandboxed readable preference domains, verify an explicit domain-qualified read and schema validation; do not rely on undocumented cross-app `standard` defaults.
3. For inaccessible domains or missing entitlements, require user-assisted export from Runner or explicit user-selected source; do not bypass macOS sandbox permissions or silently scan other app containers.
4. Inventory every selected preference key with type, fallback, destination namespace and old→new asset ID mapping. If an optional preference cannot be acquired, report it `notImported`; never silently label the entire import complete.
5. Copy/read-back character library and productivity files under new app ownership with source-size budgets, symlink/path safeguards and schema-version checks. Do not change the original.
6. Use a versioned migration journal with `sourceBundleID`, `sourceSchemaVersion`, `sourceFingerprint`, `migrationVersion`, per-domain states and stable old→new UUID mappings. Make retries and interrupted migrations idempotent.
7. Keep notification **activation** separate from data import and subject to the [handoff contract](notification-handoff-contract.md). The imported reminder definition can exist while disabled.

## Error and rollback

- `sourceUnavailable`, `permissionDenied`, `unsupportedSchema`, `invalidAsset`, `stagingFailed`, `partiallyImported`, `migrationCompleteWithOmissions`, `migrationComplete` are distinct nonsecret outcomes.
- Invalid preferences do not require all core data to be discarded, but omissions must be visible and never misrepresented as full import.
- Import staging is bounded and atomically promoted after reload. Source files/old defaults are not deleted or modified.
- Rolling back SchneeBar removes only new migration-owned state and notification requests; it does not remove original Runner settings or files.
- Never copy GitHub credentials, and never write a private source path to telemetry.

## Required acceptance fixtures

- Import from a different bundle ID where UserDefaults is accessible vs not accessible.
- Character ID maps to missing, duplicated, or malformed asset; fallback retained without stale pointer.
- File copied but preference extraction failed; partial outcome shown and idempotent retry.
- App killed before migration marker write; same input cannot produce duplicate history or asset records.
- Imported reminder definition never schedules while handoff remains unverified.
