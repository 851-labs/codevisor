import Foundation

/// `PersistenceStore` adapter used by all existing client repositories.
public final class SQLitePersistenceStore:
    PersistenceStore,
    ClientDataResetting,
    @unchecked Sendable
{
    public let database: ClientDatabase

    public init(database: ClientDatabase) {
        self.database = database
    }

    public func loadData(forKey key: String) -> Data? {
        do {
            return try database.value(forKey: key)
        } catch {
            Log.persistence.error(
                "Failed to read \(key, privacy: .public) from client SQLite: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        try database.setValue(data, forKey: key)
    }

    public func removeData(forKey key: String) throws {
        try database.removeValue(forKey: key)
    }

    public func quarantineCorruptData(forKey key: String) {
        do {
            try database.quarantineValue(forKey: key)
        } catch {
            Log.persistence.error(
                "Failed to quarantine \(key, privacy: .public) in client SQLite: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func resetClientData() throws {
        try database.resetClientData()
    }
}

/// Live native persistence: structured payloads are SQLite rows, while large
/// draft attachment bytes stay as managed assets under one subdirectory.
/// SQLite still owns the asset manifest, migration history, and every other
/// client value.
public final class ClientPersistenceStore:
    PersistenceStore,
    ClientDataResetting,
    @unchecked Sendable
{
    public static let assetDirectoryName = "ClientAssets"

    private static let blobKeyPrefix = "composer-draft-attachment-"

    public let database: ClientDatabase

    private let values: SQLitePersistenceStore
    private let blobDirectory: URL
    private let blobs: FileSystemStore
    private let fileManager: FileManager

    public init(
        database: ClientDatabase,
        directory: URL,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.values = SQLitePersistenceStore(database: database)
        self.fileManager = fileManager
        self.blobDirectory =
            directory
            .appendingPathComponent(Self.assetDirectoryName, isDirectory: true)
            .appendingPathComponent("DraftAttachments", isDirectory: true)
        self.blobs = FileSystemStore(
            directory: blobDirectory,
            fileManager: fileManager
        )
    }

    public func loadData(forKey key: String) -> Data? {
        if Self.isBlobKey(key) {
            return blobs.loadData(forKey: key)
        }
        return values.loadData(forKey: key)
    }

    public func saveData(_ data: Data, forKey key: String) throws {
        guard Self.isBlobKey(key) else {
            try values.saveData(data, forKey: key)
            return
        }
        try blobs.saveData(data, forKey: key)
        try database.recordBlobAsset(
            key: key,
            data: data,
            relativePath: "DraftAttachments/\(key).json"
        )
    }

    public func removeData(forKey key: String) throws {
        guard Self.isBlobKey(key) else {
            try values.removeData(forKey: key)
            return
        }
        try blobs.removeData(forKey: key)
        try database.removeBlobAsset(key: key)
    }

    public func quarantineCorruptData(forKey key: String) {
        if Self.isBlobKey(key) {
            blobs.quarantineCorruptData(forKey: key)
        } else {
            values.quarantineCorruptData(forKey: key)
        }
    }

    public func flushBlobWrites() {
        blobs.flushPendingWrites()
    }

    public func resetClientData() throws {
        blobs.flushPendingWrites()
        if fileManager.fileExists(atPath: blobDirectory.path) {
            try fileManager.removeItem(at: blobDirectory)
        }
        try fileManager.createDirectory(
            at: blobDirectory,
            withIntermediateDirectories: true
        )
        try database.resetClientData()
    }

    private static func isBlobKey(_ key: String) -> Bool {
        key.hasPrefix(blobKeyPrefix)
    }
}
