import Foundation

/// A simple key-addressable byte store, abstracted so repositories can be
/// tested in memory without touching the file system.
public protocol PersistenceStore: Sendable {
    func loadData(forKey key: String) -> Data?
    func saveData(_ data: Data, forKey key: String) throws
}

/// A `PersistenceStore` backed by JSON files in the app's Application Support
/// directory.
public final class FileSystemStore: PersistenceStore, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        appFolderName: String = "HerdMan"
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
    }

    private func url(forKey key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    public func loadData(forKey key: String) -> Data? {
        try? Data(contentsOf: url(forKey: key))
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        try data.write(to: url(forKey: key), options: .atomic)
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
