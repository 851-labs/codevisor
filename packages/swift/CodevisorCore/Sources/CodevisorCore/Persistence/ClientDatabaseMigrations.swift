public enum ClientDatabaseMigrations {
  public static let all: [ClientSchemaMigration] = [
    ClientSchemaMigration(
      id: 1,
      name: "initial client persistence",
      sql:
        """
        CREATE TABLE client_values (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_preferences (
            key TEXT PRIMARY KEY,
            value BLOB NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_quarantine (
            id TEXT PRIMARY KEY,
            original_key TEXT NOT NULL,
            value BLOB NOT NULL,
            quarantined_at TEXT NOT NULL
        );

        CREATE TABLE client_blob_assets (
            key TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL,
            digest TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE client_data_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('running', 'completed', 'failed')),
            cursor TEXT,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            last_error TEXT
        );

        CREATE TABLE client_cleanup_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN ('running', 'completed', 'failed')),
            cursor TEXT,
            started_at TEXT NOT NULL,
            completed_at TEXT,
            last_error TEXT
        );

        CREATE TABLE client_migration_artifacts (
            migration_id INTEGER NOT NULL,
            source TEXT NOT NULL,
            digest TEXT NOT NULL,
            imported INTEGER NOT NULL DEFAULT 0 CHECK(imported IN (0, 1)),
            cleaned INTEGER NOT NULL DEFAULT 0 CHECK(cleaned IN (0, 1)),
            updated_at TEXT NOT NULL,
            PRIMARY KEY (migration_id, source)
        );

        CREATE TABLE client_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
    )
  ]
}
