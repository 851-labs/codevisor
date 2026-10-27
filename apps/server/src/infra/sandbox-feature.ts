import { SANDBOXES_FEATURE_FLAG, sandboxesFlagOn } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { run } from "../server-context.js"
import type { SandboxRecordStore } from "./sandbox-store.js"

export const sandboxWorkPending = async (
  db: Pick<CodevisorDatabaseService, "getSyncEntries">,
  records: Pick<SandboxRecordStore, "list">
): Promise<boolean> => {
  if (sandboxesFlagOn(await run(db.getSyncEntries(SANDBOXES_FEATURE_FLAG.namespace)))) return true
  return (await records.list()).length > 0
}
