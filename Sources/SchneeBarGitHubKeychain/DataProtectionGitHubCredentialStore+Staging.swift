import SchneeBarGitHub

/// Opt-in only. No application code currently constructs or invokes a
/// migration stager against the production Keychain stores.
extension DataProtectionGitHubCredentialStore:
    GitHubCredentialEnrollmentStagingDestination {}
