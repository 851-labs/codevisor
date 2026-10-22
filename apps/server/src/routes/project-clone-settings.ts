import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { isAbsolute, resolve } from "node:path"

import type { ProjectCloneSettings } from "@codevisor/api"
import { UpdateProjectCloneSettingsRequest as UpdateProjectCloneSettingsRequestSchema } from "@codevisor/api"
import { defaultCloneBaseFolder, type CodevisorDatabaseService } from "@codevisor/db"

import { HttpFailure, readSchema, run, writeJson } from "../server-context.js"

const BASE_FOLDER_SETTING = "project-clone-base-folder"

export const cloneBaseFolder = async (db: CodevisorDatabaseService): Promise<string> =>
  (await run(db.getMachineSetting(BASE_FOLDER_SETTING))) ?? defaultCloneBaseFolder()

const settings = async (db: CodevisorDatabaseService): Promise<ProjectCloneSettings> => ({
  baseFolder: await cloneBaseFolder(db),
  defaultBaseFolder: defaultCloneBaseFolder()
})

const expandedFolder = (raw: string): string => {
  const expanded = raw.trim().replace(/^~(?=$|\/)/, homedir())
  if (!isAbsolute(expanded)) {
    throw new HttpFailure(400, "Choose an absolute folder, like ~/src", "invalid")
  }
  return resolve(expanded)
}

export const routeProjectCloneSettings = async (
  db: CodevisorDatabaseService,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  if (request.method === "PUT") {
    const payload = await readSchema(request, UpdateProjectCloneSettingsRequestSchema)
    const folder =
      payload.baseFolder === null || payload.baseFolder.trim().length === 0
        ? undefined
        : expandedFolder(payload.baseFolder)
    await run(
      db.setMachineSetting(
        BASE_FOLDER_SETTING,
        folder === defaultCloneBaseFolder() ? undefined : folder
      )
    )
  }
  writeJson(response, 200, await settings(db))
}
