import Foundation

/// One-time rescue for the 851labs → Codevisor, LLC identity migration: the
/// shipping bundle id changed (com.851labs.HerdMan → com.codevisor.macos),
/// which moves the UserDefaults domain out from under every existing install.
/// Copies each legacy key the new domain doesn't define yet — window frames,
/// Sparkle's SU* bookkeeping, and any stray preference — then never runs
/// again. File-backed data needs no rescue: Application Support is named
/// "Codevisor", not derived from the bundle id.
public enum LegacyDefaultsMigration {
    public static let legacyDomain = "com.851labs.HerdMan"
    public static let markerKey = "codevisor.legacyDefaultsMigrated"

    public static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        // Dev builds never shipped under the legacy identity.
        guard !CodevisorAppVariant.isDevelopment else { return }
        apply(legacy: defaults.persistentDomain(forName: legacyDomain) ?? [:], to: defaults)
    }

    /// Marker-guarded merge, separated from the domain read so tests can
    /// exercise it against a scratch suite. Existing keys always win: a value
    /// the renamed app already wrote is newer than anything in the legacy
    /// domain.
    static func apply(legacy: [String: Any], to defaults: UserDefaults) {
        guard !defaults.bool(forKey: markerKey) else { return }
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: markerKey)
    }
}
