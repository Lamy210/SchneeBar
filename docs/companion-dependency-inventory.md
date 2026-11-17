# Companion dependency inventory

Scope: independent development branch, not production approval. Runner baseline c925816d4f7ec4e07a5c6db74fd6038fea3aa71d (Package.swift, Swift tools 6.0, macOS 14+). Runner declares no external Swift package dependencies. Its own targets are SchneeRunnerCore, SchneeRunnerApp, SchneeRunnerCtl and their tests. App resources include BuiltInCharacters and en/ja localization. No Runner target or resources are imported by this change.

| Responsibility | Bar integration | Dependency rule |
| --- | --- | --- |
| State, timing, CPU policy | SchneeBarCompanionCore | Foundation/pure domain, no GitHub/AppKit |
| Image IO and bounded file reader | SchneeBarCompanionAssets | CompanionCore + platform frameworks; no third-party decoder |
| Async selected-file staging | CompanionSingleFileImporter / CompanionImportQueue | one queue, no persistence, no UI or privilege |
| Animation and runtime | SchneeBarCompanionFeature | Core, Assets, DesignSystem |
| Host CPU | SchneeBarSystemProvider | existing SchneeBarCore, shared actor |
| Independent preview | SchneeBarCompanionPreview | above modules and existing DesignSystem; not referenced by shipping SchneeBar |
| Local CLI/build events | pending typed adapter | preserve wire compatibility; no command or credential authority |
| Pack storage, desktop, Focus | pending separate slices | approval and evidence required |

The integration branch inherits PRs #388–#392 through the stacked commit ancestry. Main contains the merged specification PR #387. Keep the existing Tuist toolchain and macOS 15+ target; no new package manager, external dependency, submodule, direct source copy, or artwork import. A conventional LICENSE and DISTRIBUTION_TERMS.md were not found at the checked Runner baseline root; this is not a complete rights audit or an assertion that reuse is forbidden/allowed. Record explicit rights disposition before copying source/resources. Preserve the production app's existing GitHub boundary and current release workflow.

Next: complete native integration tests, then a separate approved file-selection and lifecycle connection, before introducing pack migration or production app dependencies.
