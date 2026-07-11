import os

/// Centralized handles into the unified logging system (Console.app,
/// `log stream --predicate 'subsystem == "com.851labs.herdman"'`).
///
/// Every error the app absorbs — even ones that are fine to swallow from the
/// user's point of view — must leave a trace here so failures are diagnosable
/// after the fact. Use `.error` for failed operations, `.fault` for broken
/// invariants (corrupt shipped assets, impossible states).
///
/// Interpolated error strings should use `privacy: .public`: the default
/// redaction turns release-build diagnostics into `<private>`, which defeats
/// the purpose. Never log message bodies, tokens, or file contents.
public enum Log {
    public static let subsystem = "com.851labs.herdman"

    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let server = Logger(subsystem: subsystem, category: "server")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let machines = Logger(subsystem: subsystem, category: "machines")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let theming = Logger(subsystem: subsystem, category: "theming")
    public static let terminal = Logger(subsystem: subsystem, category: "terminal")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
    public static let attachments = Logger(subsystem: subsystem, category: "attachments")
    public static let scratchpad = Logger(subsystem: subsystem, category: "scratchpad")
    public static let onboarding = Logger(subsystem: subsystem, category: "onboarding")
    /// Errors that were also surfaced to the user (mirrors every
    /// `ErrorReporter.report` so the banner text is findable in logs).
    public static let surfaced = Logger(subsystem: subsystem, category: "surfaced")
}
