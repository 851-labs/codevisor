import Foundation

/// A simple key-addressable byte store, abstracted so repositories can be
/// tested in memory without touching the file system.
public protocol PersistenceStore: Sendable {
    func loadData(forKey key: String) -> Data?
    func saveData(_ data: Data, forKey key: String) throws
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
    private let writeQueue = DispatchQueue(label: "com.herdman.persistence-write", qos: .utility)
    private let pendingLock = NSLock()
    /// Latest not-yet-flushed bytes per key — the coalescing buffer and the
    /// read-your-writes source.
    private var pending: [String: Data] = [:]
    private var terminationObserver: (any NSObjectProtocol)?

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        appFolderName: String = HerdManAppVariant.applicationSupportDirectoryName
    ) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            self.directory = base.appendingPathComponent(appFolderName, isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)

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
        return try? Data(contentsOf: url(forKey: key))
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
            try? payload.write(to: self.url(forKey: key), options: .atomic)
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
