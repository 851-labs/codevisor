import CryptoKit
import Foundation

extension ClientDatabase {
    public func value(forKey key: String) throws -> Data? {
        try lock.withLock {
            try queryData(
                "SELECT value FROM client_values WHERE key = ?",
                bindings: [.text(key)]
            )
        }
    }

    public func setValue(_ value: Data, forKey key: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_values (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
                bindings: [.text(key), .blob(value), .text(Self.timestamp())]
            )
        }
    }

    public func removeValue(forKey key: String) throws {
        try lock.withLock {
            try executePrepared(
                "DELETE FROM client_values WHERE key = ?",
                bindings: [.text(key)]
            )
        }
    }

    public func preference(forKey key: String) throws -> Data? {
        try lock.withLock {
            try queryData(
                "SELECT value FROM client_preferences WHERE key = ?",
                bindings: [.text(key)]
            )
        }
    }

    public func setPreference(_ value: Data, forKey key: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_preferences (key, value, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at
                """,
                bindings: [.text(key), .blob(value), .text(Self.timestamp())]
            )
        }
    }

    public func removePreference(forKey key: String) throws {
        try lock.withLock {
            try executePrepared(
                "DELETE FROM client_preferences WHERE key = ?",
                bindings: [.text(key)]
            )
        }
    }

    public func removeAllPreferences() throws {
        try lock.withLock {
            try execute("DELETE FROM client_preferences;")
        }
    }

    public func resetClientData() throws {
        try lock.withLock {
            try withTransaction {
                try execute("DELETE FROM client_values;")
                try execute("DELETE FROM client_preferences;")
                try execute("DELETE FROM client_quarantine;")
                try execute("DELETE FROM client_blob_assets;")
                try execute("DELETE FROM client_metadata;")
            }
        }
    }

    public func recordBlobAsset(key: String, data: Data, relativePath: String) throws {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_blob_assets
                    (key, relative_path, digest, byte_count, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    relative_path = excluded.relative_path,
                    digest = excluded.digest,
                    byte_count = excluded.byte_count,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(key),
                    .text(relativePath),
                    .text(digest),
                    .integer(Int64(data.count)),
                    .text(Self.timestamp()),
                ]
            )
        }
    }

    public func removeBlobAsset(key: String) throws {
        try lock.withLock {
            try executePrepared(
                "DELETE FROM client_blob_assets WHERE key = ?",
                bindings: [.text(key)]
            )
        }
    }

    public func quarantineValue(forKey key: String) throws {
        try lock.withLock {
            try withTransaction {
                guard let value = try value(forKey: key) else { return }
                try executePrepared(
                    """
                    INSERT INTO client_quarantine
                        (id, original_key, value, quarantined_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(UUID().uuidString),
                        .text(key),
                        .blob(value),
                        .text(Self.timestamp()),
                    ]
                )
                try removeValue(forKey: key)
            }
        }
    }
}
