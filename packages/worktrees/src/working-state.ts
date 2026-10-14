import { constants } from "node:fs"
import { copyFile, mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

import { runGit } from "./git.js"

export const scratchIndexConfig = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false"]

export const heavyGit = { priority: "utility", maxBuffer: 256 * 1024 * 1024 } as const

const codevisorIdentityName = "Codevisor"
const codevisorIdentityEmail = "noreply@codevisor.app"

export interface ScratchIndex {
  readonly indexFile: string
  readonly env: NodeJS.ProcessEnv
}

export const withScratchIndex = async <A>(
  env: NodeJS.ProcessEnv | undefined,
  work: (scratch: ScratchIndex) => Promise<A>
): Promise<A> => {
  const scratchDir = await mkdtemp(join(tmpdir(), "codevisor-index-"))
  const indexFile = join(scratchDir, "index")
  try {
    return await work({
      indexFile,
      env: {
        ...(env ?? process.env),
        GIT_INDEX_FILE: indexFile,
        GIT_AUTHOR_NAME: codevisorIdentityName,
        GIT_AUTHOR_EMAIL: codevisorIdentityEmail,
        GIT_COMMITTER_NAME: codevisorIdentityName,
        GIT_COMMITTER_EMAIL: codevisorIdentityEmail
      }
    })
  } finally {
    /* v8 ignore next */
    await rm(scratchDir, { force: true, recursive: true }).catch(() => undefined)
  }
}

export const copyRealIndex = async (
  dir: string,
  scratch: ScratchIndex,
  env?: NodeJS.ProcessEnv
): Promise<void> => {
  const realIndex = await runGit("index-path", ["rev-parse", "--git-path", "index"], dir, env)
  await copyFile(resolve(dir, realIndex), scratch.indexFile, constants.COPYFILE_FICLONE)
}

export const writeWorkingTree = async (dir: string, scratch: ScratchIndex): Promise<string> => {
  await runGit("add", [...scratchIndexConfig, "add", "-A"], dir, scratch.env, heavyGit)
  return runGit("write-tree", [...scratchIndexConfig, "write-tree"], dir, scratch.env, heavyGit)
}
