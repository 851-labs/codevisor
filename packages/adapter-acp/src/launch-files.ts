import { randomUUID } from "node:crypto"
import { mkdir, rename, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import type { HarnessDefinition, HarnessLaunchFile } from "@codevisor/agent-runtime"

export const defaultLaunchFilesDirectory = (env: NodeJS.ProcessEnv = process.env): string =>
  join(env.CODEVISOR_DATA_DIR ?? join(homedir(), ".codevisor", "data"), "harness-launch")

const launchFiles = (definition: HarnessDefinition): ReadonlyArray<HarnessLaunchFile> =>
  definition.launch?.kind === "executable" ? (definition.launch.files ?? []) : []

const writeAtomically = async (path: string, contents: string): Promise<void> => {
  const staging = `${path}.${randomUUID()}`
  await writeFile(staging, contents, { mode: 0o600 })
  await rename(staging, path)
}

const writeLaunchFile = async (
  directory: string,
  file: HarnessLaunchFile
): Promise<ReadonlyArray<string>> => {
  const path = join(directory, file.name)
  await writeAtomically(path, file.contents)
  return [file.flag, path]
}

export const writeLaunchFiles = async (
  directory: string,
  definition: HarnessDefinition
): Promise<ReadonlyArray<string>> => {
  const files = launchFiles(definition)
  if (files.length === 0) return []

  const harnessDirectory = join(directory, definition.id)
  await mkdir(harnessDirectory, { mode: 0o700, recursive: true })
  const args = await Promise.all(files.map((file) => writeLaunchFile(harnessDirectory, file)))
  return args.flat()
}
