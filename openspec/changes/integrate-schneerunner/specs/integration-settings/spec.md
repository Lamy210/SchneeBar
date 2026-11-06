# Spec Delta

## Purpose

Provide coherent and accessible SchneeBar settings for optional Companion, Focus and Developer features while preserving independent connectivity, preferences and safe default behavior for users who do not sign in to GitHub.

## ADDED Requirements

### Requirement: Independent module controls

The app SHALL let users enable, disable and configure Companion, Focus and Developer Activity independently without requiring unrelated service credentials.

#### Scenario: User disables GitHub integrations
- **WHEN** the user disables Developer Activity while a timer and desktop character are active
- **THEN** the timer and character SHALL continue operating and no new GitHub requests SHALL be initiated by the disabled feature.

#### Scenario: User enables Companion without account
- **WHEN** the user enables Companion with no connected GitHub account
- **THEN** local animation and CPU reactions SHALL remain available without prompting for GitHub authentication.

### Requirement: Presentation presets do not change authorization

The app SHALL offer Minimal, Dashboard and Companion presentation presets without granting additional service permissions or implicitly enabling write operations.

#### Scenario: User switches to Companion mode
- **WHEN** the user selects the Companion preset
- **THEN** visual composition MAY change but GitHub connection permissions and write authorization SHALL remain unchanged.

### Requirement: Preferences have explainable states

The app SHALL present disabled, loading, unavailable and permission-required states for each module without hiding its stored preferences or inventing connectivity.

#### Scenario: GitHub account requires recovery
- **WHEN** GitHub returns a verified reauthentication-required state
- **THEN** the connection view SHALL offer recovery and Focus/Companion preferences SHALL remain editable.

### Requirement: Localization and accessibility remain consistent

The app SHALL provide keyboard-accessible controls, VoiceOver descriptions and reduced-motion behavior for each integrated feature, with usable Japanese and English labels.

#### Scenario: User enables Reduce Motion
- **WHEN** macOS Reduce Motion is enabled while Companion is active
- **THEN** animated motion SHALL be reduced without hiding essential status information or controls.
