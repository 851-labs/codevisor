import Foundation

extension ClientDatabase {
    public func dataMigrationState(id: Int) throws -> String? {
        try lock.withLock {
            try queryText(
                "SELECT state FROM client_data_migrations WHERE id = ?",
                bindings: [.integer(Int64(id))]
            )
        }
    }

    public func beginDataMigration(id: Int, name: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_data_migrations
                    (id, name, state, cursor, started_at, completed_at, last_error)
                VALUES (?, ?, 'running', NULL, ?, NULL, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    state = 'running',
                    started_at = excluded.started_at,
                    completed_at = NULL,
                    last_error = NULL
                """,
                bindings: [.integer(Int64(id)), .text(name), .text(Self.timestamp())]
            )
        }
    }

    public func completeDataMigration(id: Int) throws {
        try lock.withLock {
            try executePrepared(
                """
                UPDATE client_data_migrations
                SET state = 'completed', completed_at = ?, last_error = NULL
                WHERE id = ?
                """,
                bindings: [.text(Self.timestamp()), .integer(Int64(id))]
            )
        }
    }

    public func failDataMigration(id: Int, error: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                UPDATE client_data_migrations
                SET state = 'failed', last_error = ?
                WHERE id = ?
                """,
                bindings: [.text(error), .integer(Int64(id))]
            )
        }
    }

    public func cleanupMigrationState(id: Int) throws -> String? {
        try lock.withLock {
            try queryText(
                "SELECT state FROM client_cleanup_migrations WHERE id = ?",
                bindings: [.integer(Int64(id))]
            )
        }
    }

    public func beginCleanupMigration(id: Int, name: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_cleanup_migrations
                    (id, name, state, cursor, started_at, completed_at, last_error)
                VALUES (?, ?, 'running', NULL, ?, NULL, NULL)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    state = 'running',
                    started_at = excluded.started_at,
                    completed_at = NULL,
                    last_error = NULL
                """,
                bindings: [.integer(Int64(id)), .text(name), .text(Self.timestamp())]
            )
        }
    }

    public func completeCleanupMigration(id: Int) throws {
        try lock.withLock {
            try executePrepared(
                """
                UPDATE client_cleanup_migrations
                SET state = 'completed', completed_at = ?, last_error = NULL
                WHERE id = ?
                """,
                bindings: [.text(Self.timestamp()), .integer(Int64(id))]
            )
        }
    }

    public func failCleanupMigration(id: Int, error: String) throws {
        try lock.withLock {
            try executePrepared(
                """
                UPDATE client_cleanup_migrations
                SET state = 'failed', last_error = ?
                WHERE id = ?
                """,
                bindings: [.text(error), .integer(Int64(id))]
            )
        }
    }

    public func recordMigrationArtifact(
        migrationID: Int,
        source: String,
        digest: String,
        imported: Bool,
        cleaned: Bool
    ) throws {
        try lock.withLock {
            try executePrepared(
                """
                INSERT INTO client_migration_artifacts
                    (migration_id, source, digest, imported, cleaned, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(migration_id, source) DO UPDATE SET
                    digest = excluded.digest,
                    imported = excluded.imported,
                    cleaned = excluded.cleaned,
                    updated_at = excluded.updated_at
                """,
                bindings: [
                    .integer(Int64(migrationID)),
                    .text(source),
                    .text(digest),
                    .integer(imported ? 1 : 0),
                    .integer(cleaned ? 1 : 0),
                    .text(Self.timestamp()),
                ]
            )
        }
    }
}
