import CodevisorCore

/// Decides when the server-availability screen may offer an exit to this
/// Mac. The composer remembers the machine it last targeted; a remembered
/// remote machine that is offline would otherwise hold the whole New Chat
/// page hostage, since the machine picker lives inside the blocked composer.
public enum ServerAvailabilityFallbackPolicy {
    /// Whether to show "Use This Mac Instead".
    ///
    /// Only remote machines qualify (the local server has nothing to fall
    /// back to), only while the wait is open-ended — connecting or failed —
    /// and never during a known-finite transition (server update or restart,
    /// app update, data migration), where the honest answer is "wait".
    public static func offersLocalMachine(
        isLocal: Bool,
        availability: ServerAvailability,
        hasLocalMachine: Bool,
        appUpdateInProgress: Bool = false,
        migrationInProgress: Bool = false
    ) -> Bool {
        guard !isLocal, hasLocalMachine, !appUpdateInProgress, !migrationInProgress else {
            return false
        }
        switch availability {
        case .waiting(.starting), .waiting(.connecting), .failed:
            return true
        case .waiting(.updating), .waiting(.restarting), .ready:
            return false
        }
    }
}
