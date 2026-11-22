# UX follow-up: narrow long-name GitHub management visual coverage

## Goal
PR #464 added compact capability-status display logic, but the baseline Visual Regression CLI currently renders the GitHub connection management surface at 760 pt and does not isolate extremely long repository names. Add deterministic fixtures so subsequent UI changes can be compared visually at a near-minimum supported width, rather than relying only on unit tests of badge-count strings.

## Fixture
- A synthetic GitHub Enterprise management model with three repository names significantly longer than the natural row width, a private and public row, and mixed unavailable/unverified/available action sources.
- Exact stable UUIDs and numeric repository IDs. Never use live credentials, real private repository names, API/network requests or mutable state.
- Expose the fixture through the existing human-driven VisualHarness scenario picker. Do not change the default scenario, shipped app behavior or live GitHub scope.
- Add a separate `github-management-dense-long-name-{light,dark}.png` snapshot rendered by `SchneeBarVisualSnapshotCLI` at **680 pt** outer width. Existing 760 pt snapshots and file names must remain unchanged.

## Acceptance
- macOS visual CLI successfully renders both new snapshots and produces an informative visual report in the PR (new image baselines are expected; do not assert a pixel diff without inspecting actual screenshots).
- Swift macOS Build/Test and OpenSpec strict pass. Review new image artifacts for label clipping, selection toggle visibility, private marker readability and compact capability summaries.
- Manual real-Mac VoiceOver, keyboard and increased-text-size verification remains open in issue #360; a bitmap alone cannot validate those modalities.
- Merge to `main` only after CI/visual review, then synchronize to `integration/schneerunner` under #396's unchanged release gates.


## Defect reproduced by the new fixture
Actual PR #467 Visual Regression artifact (680 pt, both light and dark) shows the optional "Private" text wrapping into a vertical column on the right and the first row's selection control appearing compressed. This is a **verified visual defect**; a successful snapshot job proves only that the screenshot was generated, not that the layout is correct.

The PR must therefore also correct the repository row: keep the selection toggle at its intrinsic width, allow the repository name to truncate, expose privacy from the always-visible lock icon with help and VoiceOver, and hide the *redundant* "Private" word if it cannot fit on one line. Review the newly generated candidate images again, in both appearances, before merging.
