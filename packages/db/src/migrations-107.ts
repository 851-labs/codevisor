import type { DataUpgradeProgress } from "@codevisor/api"

import { startArchiveRetentionGrace } from "./machine-settings-service.js"
import type { Migration } from "./migration-types.js"
import type { CodevisorDatabaseConfig } from "./service.js"
import { chatFileSourceCount, linkStoredChatFiles } from "./session-files.js"

const linkingId = "chat-owned-files-v2"

const linkingName = "Linking attachments"

const reportLinking = (
  config: CodevisorDatabaseConfig,
  state: DataUpgradeProgress["state"],
  completed: number
): void => {
  config.onDataUpgradeProgress?.({
    state,
    id: linkingId,
    name: linkingName,
    completed,
    total: chatFileSourceCount()
  })
}

export const migrations107: ReadonlyArray<Migration> = [
  {
    id: 107,
    name: "a chat releases its files however it is deleted",
    sql: `
      create trigger session_files_release_file after delete on session_files
      begin
        delete from files where id = old.file_id and purge_with_chats = 1
          and not exists (select 1 from session_files where file_id = old.file_id);
      end;
    `,
    run: (sqlite, config) => {
      reportLinking(config, "running", 0)
      linkStoredChatFiles(sqlite, (linked) => reportLinking(config, "running", linked))
      reportLinking(config, "completed", chatFileSourceCount())
      startArchiveRetentionGrace(sqlite)
    }
  }
]
