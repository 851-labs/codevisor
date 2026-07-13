import Foundation

/// A simple key-addressable byte store, abstracted so repositories can be
/// tested in memory without touching the file system.
public protocol PersistenceStore: Sendable {
    func loadData(forKey key: String) -> Data?
    func saveData(_ data: Data, forKey key: String) throws
    /// Moves the persisted payload for `key` aside after a decode failure so
    /// the next save doesn't overwrite the evidence. Stores without durable
    /// files can rely on the default no-op.
    func quarantineCorruptData(forKey key: String)
}

extension PersistenceStore {
    public func quarantineCorruptData(forKey key: String) {}
}

/// Shared handling for a persisted payload that failed to decode: quarantines
/// the on-disk file (keeping a backup instead of letting the next save
/// overwrite it), logs a fault, and optionally surfaces a banner. Empty
/// payloads are logged but not quarantined — there is nothing to back up.
func handleCorruptPayload(
    store: any PersistenceStore,
    key: String,
    data: Data,
    error: any Error,
    reportTitle: String? = nil,
    reportMessage: String? = nil
) {
    guard !data.isEmpty else {
        Log.persistence.error("Empty persisted payload for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        return
    }
    store.quarantineCorruptData(forKey: key)
    Log.persistence.fault("Corrupt persisted payload for \(key, privacy: .public); kept a backup: \(String(describing: error), privacy: .public)")
    guard let reportTitle else { return }
    Task { @MainActor in
        ErrorReporter.shared.report(reportTitle, message: reportMessage)
    }
}

/// A `PersistenceStore` backed by JSON files in the app's Application Support
/// directory.
///
/// Writes are asynchronous: callers are `@MainActor` models on hot
/// interaction paths (turn end, pane tab clicks, sidebar mutations), and a
/// disk stall — Spotlight, low disk, a network home directory — must never
/// block the run loop. Saves per key coalesce (last write wins), reads see
/// pending writes immediately, and pending writes flush before the app
/// terminates.
public final class FileSystemStore: PersistenceStore, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    /// Serial queue all disk writes run on.
    private let writeQueue = DispatchQueue(label: "com.codevisor.persistence-write", qos: .utility)
    private let pendingLock = NSLock()
    /// Latest not-yet-flushed bytes per key — the coalescing buffer and the
    /// read-your-writes source.
    private var pending: [String: Data] = [:]
    /// Keys whose failed writes were already surfaced to the user this run,
    /// so a repeatedly failing save logs every time but banners once.
    private var reportedWriteFailures: Set<String> = []
    private var terminationObserver: (any NSObjectProtocol)?
    /// Called (on the write queue) when a queued disk write fails. When nil,
    /// the failure is surfaced through `ErrorReporter` on the main actor.
    private let onWriteFailure: (@Sendable (String, any Error) -> Void)?

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        appFolderName: String = CodevisorAppVariant.applicationSupportDirectoryName,
        onWriteFailure: (@Sendable (String, any Error) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.onWriteFailure = onWriteFailure
        if let directory {
            self.directory = directory
        } else {
            let base: URL
            do {
                base = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            } catch {
                base = fileManager.temporaryDirectory
                Log.persistence.fault("Application Support is unavailable; falling back to the temporary directory: \(String(describing: error), privacy: .public)")
                Task { @MainActor in
                    ErrorReporter.shared.report(
                        "Codevisor Can't Access Its Data Folder",
                        message: "Changes made now may not be saved after you quit."
                    )
                }
            }
            self.directory = base.appendingPathComponent(appFolderName, isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Failed to create data directory \(self.directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        // Drain queued writes before the process exits so a state change
        // made just before quitting isn't lost. Name-based so this Foundation
        // package needs no AppKit import; the store lives for the app's
        // lifetime, so the retained closure is fine.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flushPendingWrites()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        flushPendingWrites()
    }

    private func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    public func loadData(forKey key: String) -> Data? {
        if let queued = pendingLock.withLock({ pending[key] }) { return queued }
        do {
            return try Data(contentsOf: url(forKey: key))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A fresh key with no file yet is the normal empty state.
            return nil
        } catch {
            Log.persistence.error("Failed to read \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        let alreadyScheduled: Bool = pendingLock.withLock {
            let scheduled = pending[key] != nil
            pending[key] = data
            return scheduled
        }
        // A write for this key is already queued; it will pick up the newer
        // bytes when it runs.
        guard !alreadyScheduled else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            let payload: Data? = self.pendingLock.withLock {
                let data = self.pending[key]
                self.pending[key] = nil
                return data
            }
            guard let payload else { return }
            do {
                try payload.write(to: self.url(forKey: key), options: .atomic)
            } catch {
                Log.persistence.error("Failed to write \(key, privacy: .public): \(String(describing: error), privacy: .public)")
                self.notifyWriteFailure(key: key, error: error)
            }
        }
    }

    /// Surfaces a failed disk write. A custom handler gets every failure; the
    /// default banner fires at most once per key per app run (each occurrence
    /// is still logged above).
    private func notifyWriteFailure(key: String, error: any Error) {
        if let onWriteFailure {
            onWriteFailure(key, error)
            return
        }
        let isFirstForKey = pendingLock.withLock { reportedWriteFailures.insert(key).inserted }
        guard isFirstForKey else { return }
        Task { @MainActor in
            ErrorReporter.shared.report(
                "Couldn't Save Your Data",
                message: "Codevisor couldn't write “\(key)” to its data folder, so recent changes may be lost. Check that your disk isn't full."
            )
        }
    }

    /// Renames the payload file for `key` to `<name>.corrupt-<timestamp>` so
    /// corrupt data survives for diagnosis instead of being overwritten by the
    /// next save.
    public func quarantineCorruptData(forKey key: String) {
        let source = url(forKey: key)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = directory.appendingPathComponent(
            "\(source.lastPathComponent).corrupt-\(formatter.string(from: Date()))"
        )
        do {
            try fileManager.moveItem(at: source, to: destination)
            Log.persistence.fault("Quarantined corrupt \(key, privacy: .public) as \(destination.lastPathComponent, privacy: .public)")
        } catch {
            Log.persistence.error("Failed to quarantine corrupt \(key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Synchronously drains all queued writes. Called on app termination and
    /// available to tests.
    public func flushPendingWrites() {
        writeQueue.sync { }
    }
}

/// An in-memory `PersistenceStore` for tests and previews.
public final class InMemoryStore: PersistenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]

    public init(storage: [String: Data] = [:]) {
        self.storage = storage
    }

    public func loadData(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        lock.withLock { storage[key] = data }
    }
}
