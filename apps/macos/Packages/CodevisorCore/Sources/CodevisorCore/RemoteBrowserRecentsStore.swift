import Foundation

/// Remembers the folders chosen in the remote directory browser, per machine,
/// so the sheet's sidebar can offer them like an open panel's Recents. Most
/// recent first, deduplicated, capped — a convenience list, not a history.
@MainActor
public final class RemoteBrowserRecentsStore {
    private static let key = "remoteBrowserRecents"
    private static let capacity = 6

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func recents(forMachine machine: String) -> [String] {
        all()[machine] ?? []
    }

    public func record(_ path: String, forMachine machine: String) {
        var byMachine = all()
        var paths = byMachine[machine] ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        byMachine[machine] = Array(paths.prefix(Self.capacity))
        defaults.set(byMachine, forKey: Self.key)
    }

    public func remove(_ path: String, forMachine machine: String) {
        var byMachine = all()
        var paths = byMachine[machine] ?? []
        paths.removeAll { $0 == path }
        byMachine[machine] = paths.isEmpty ? nil : paths
        defaults.set(byMachine, forKey: Self.key)
    }

    private func all() -> [String: [String]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }
}
