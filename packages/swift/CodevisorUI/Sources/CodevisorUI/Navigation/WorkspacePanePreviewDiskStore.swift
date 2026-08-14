import Foundation

/// Stable identity for a workspace-local pane preview. Pane UUIDs are already
/// globally unique, but including the workspace makes ownership explicit and
/// lets callers remove a workspace's previews without consulting pane state.
public struct WorkspacePanePreviewKey: Hashable, Sendable {
    public let workspaceId: UUID
    public let paneId: UUID

    public init(workspaceId: UUID, paneId: UUID) {
        self.workspaceId = workspaceId
        self.paneId = paneId
    }

    fileprivate var filename: String {
        "v1-\(workspaceId.uuidString.lowercased())-\(paneId.uuidString.lowercased()).preview"
    }
}

/// A small stale-while-revalidate cache for pane preview bytes.
///
/// The store deliberately knows nothing about UIImage. That keeps file IO,
/// atomic replacement, protection, and LRU behavior testable in the shared
/// package while the iOS layer remains responsible for image encoding and
/// validation.
public actor WorkspacePanePreviewDiskStore {
    private struct Entry {
        let url: URL
        let byteCount: Int
        let lastAccess: Date
    }

    private let directory: URL
    private let maxEntryCount: Int
    private let maxByteCount: Int
    private let fileManager: FileManager

    public init(
        directory: URL,
        maxEntryCount: Int = 96,
        maxByteCount: Int = 64 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maxEntryCount = max(1, maxEntryCount)
        self.maxByteCount = max(1, maxByteCount)
        self.fileManager = fileManager
    }

    /// Loads last-known bytes immediately and marks them recently used. A
    /// missing file is normal; corrupt image bytes are rejected by the iOS
    /// decoder and removed through `remove`.
    public func data(for key: WorkspacePanePreviewKey) -> Data? {
        let url = url(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
        return data
    }

    public func data(
        for keys: [WorkspacePanePreviewKey]
    ) -> [WorkspacePanePreviewKey: Data] {
        var result: [WorkspacePanePreviewKey: Data] = [:]
        result.reserveCapacity(keys.count)
        for key in keys {
            if let bytes = data(for: key) {
                result[key] = bytes
            }
        }
        return result
    }

    /// Atomic replacement means a termination can leave either the old valid
    /// preview or the new valid preview, never a partially-written image.
    public func save(_ data: Data, for key: WorkspacePanePreviewKey) throws {
        try prepareDirectory()
        let destination = url(for: key)
        try data.write(to: destination, options: .atomic)
        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: destination.path
        )
        #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        #endif
        try evictIfNeeded(protecting: destination)
    }

    public func remove(_ key: WorkspacePanePreviewKey) throws {
        let destination = url(for: key)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    public func removeWorkspace(_ workspaceId: UUID) throws {
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return }
        let prefix = "v1-\(workspaceId.uuidString.lowercased())-"
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try fileManager.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    private func url(for key: WorkspacePanePreviewKey) -> URL {
        directory.appendingPathComponent(key.filename, isDirectory: false)
    }

    private func evictIfNeeded(protecting newestURL: URL) throws {
        var entries = try cacheEntries()
        var totalBytes = entries.reduce(0) { $0 + $1.byteCount }
        guard entries.count > maxEntryCount || totalBytes > maxByteCount else { return }

        entries.sort { lhs, rhs in
            if lhs.url == newestURL { return false }
            if rhs.url == newestURL { return true }
            return lhs.lastAccess < rhs.lastAccess
        }
        while entries.count > maxEntryCount || totalBytes > maxByteCount {
            guard let victim = entries.first else { break }
            entries.removeFirst()
            try fileManager.removeItem(at: victim.url)
            totalBytes -= victim.byteCount
        }
    }

    private func cacheEntries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.lastPathComponent.hasPrefix("v1-") else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }
            return Entry(
                url: url,
                byteCount: values.fileSize ?? 0,
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
    }
}
