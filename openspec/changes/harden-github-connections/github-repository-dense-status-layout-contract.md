# UX follow-up: responsive repository activity access status (issue #360)

## Problem
At the connection management window's minimum width (620 pt), a long repository name and four per-source status badges can compete for the same horizontal space. The existing view already provides accurate per-source available/unverified/unavailable information and accessible repository toggles; those semantics must be preserved.

## Contract
- Use SwiftUI `ViewThatFits(in: .horizontal)` in the per-repository row: retain four individual activity badges when there is sufficient width, otherwise render a compact count of **unavailable** and **unverified** activity sources. Do not count `available` entries as warnings; show no status surface if all four are available.
- Preserve separate status categories: `unverified` must never be described as `unavailable` or a confirmed denied permission.
- The compact status may show `2 unavailable · 1 unverified`, but its help and VoiceOver accessible label **must enumerate all four** sources and statuses (including available).
- Preserve the existing repository full name, selection toggle binding and accessibility identifier, private marker, filters, saved IDs, and monitoring semantics. No API requests or repository permissions change.
- Prioritize an at-least-truncated repository name over a forced four-badge list when horizontal space is constrained.

## Tests and acceptance
- Model fixtures: all available, mixed two-unavailable/one-unverified, only unverified, and one unavailable; verify both compact counts and detailed descriptions.
- macOS Build/Test and Visual Regression must pass. Check dense/long-name renders and VoiceOver manually before marking issue #360 complete; CI/Visual alone do not prove assistive-technology behavior.
- Merge only after required checks to main; the SchneeRunner integration branch must later receive the same commit via an explicit sync PR. Do not close #360 until other open UX tasks (keyboard, dynamic text, real-window checks) are validated.
