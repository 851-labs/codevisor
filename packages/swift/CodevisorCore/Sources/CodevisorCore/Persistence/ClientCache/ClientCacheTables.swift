enum ClientCacheTables {
  static let createSql = """
    CREATE TABLE cache_machines (
        machine_id TEXT PRIMARY KEY,
        event_cursor INTEGER NOT NULL,
        synced_at INTEGER NOT NULL
    );

    CREATE TABLE cache_projects (
        machine_id TEXT NOT NULL REFERENCES cache_machines(machine_id) ON DELETE CASCADE,
        id TEXT NOT NULL COLLATE NOCASE,
        name TEXT NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, id)
    );

    CREATE TABLE cache_workspaces (
        machine_id TEXT NOT NULL REFERENCES cache_machines(machine_id) ON DELETE CASCADE,
        id TEXT NOT NULL COLLATE NOCASE,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        is_archived INTEGER NOT NULL,
        sidebar_position TEXT,
        updated_at TEXT,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, id)
    );

    CREATE TABLE cache_chats (
        machine_id TEXT NOT NULL REFERENCES cache_machines(machine_id) ON DELETE CASCADE,
        id TEXT NOT NULL COLLATE NOCASE,
        project_id TEXT NOT NULL,
        workspace_id TEXT,
        title TEXT NOT NULL,
        updated_at TEXT,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, id)
    );

    CREATE INDEX cache_chats_by_workspace ON cache_chats (machine_id, workspace_id);

    CREATE TABLE cache_panes (
        machine_id TEXT NOT NULL REFERENCES cache_machines(machine_id) ON DELETE CASCADE,
        id TEXT NOT NULL COLLATE NOCASE,
        workspace_id TEXT NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, id)
    );

    CREATE TABLE cache_checkouts (
        machine_id TEXT NOT NULL REFERENCES cache_machines(machine_id) ON DELETE CASCADE,
        id TEXT NOT NULL COLLATE NOCASE,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, id)
    );

    CREATE TABLE cache_transcripts (
        machine_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        event_cursor INTEGER NOT NULL,
        head BLOB NOT NULL,
        runtime BLOB,
        fetched_at INTEGER NOT NULL,
        opened_at INTEGER NOT NULL,
        PRIMARY KEY (machine_id, chat_id)
    );

    CREATE TABLE cache_transcript_items (
        machine_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        before_cursor TEXT,
        payload BLOB NOT NULL,
        PRIMARY KEY (machine_id, chat_id, item_id),
        FOREIGN KEY (machine_id, chat_id) REFERENCES cache_transcripts (machine_id, chat_id) ON DELETE CASCADE
    );

    CREATE INDEX cache_transcript_items_in_order ON cache_transcript_items (machine_id, chat_id, sequence);

    CREATE TABLE cache_attachments (
        machine_id TEXT NOT NULL,
        file_id TEXT NOT NULL,
        chat_id TEXT,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        kind TEXT NOT NULL,
        seen_at INTEGER NOT NULL,
        file_name TEXT,
        file_bytes INTEGER NOT NULL DEFAULT 0,
        preview_name TEXT,
        preview_bytes INTEGER NOT NULL DEFAULT 0,
        opened_at INTEGER,
        PRIMARY KEY (machine_id, file_id)
    );

    CREATE TABLE cache_queued_sends (
        message_id TEXT PRIMARY KEY,
        machine_id TEXT NOT NULL,
        chat_id TEXT NOT NULL,
        text TEXT NOT NULL,
        attachments BLOB NOT NULL,
        route TEXT NOT NULL,
        state TEXT NOT NULL,
        failure TEXT,
        queued_at INTEGER NOT NULL
    );

    CREATE INDEX cache_queued_sends_by_chat ON cache_queued_sends (machine_id, chat_id);
    """
}
