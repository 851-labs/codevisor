import { mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { SavedProjectWork, type Sandbox } from "@codevisor/api"
import type { SandboxProvider } from "@codevisor/sandboxes"
import { Schema } from "effect"

import { sandboxRemote, type SandboxRemote } from "./sandbox-remote.js"
import { forgetBroughtBackChats, keptChatsOf, type KeptChats } from "./sandbox-saved-chats.js"
import type { SandboxSetupProgress } from "./sandbox-setup-log.js"
import type { SandboxDeps } from "./sandboxes.js"

export interface SavedWorkStore {
  readonly put: (workspaceId: string, work: SavedProjectWork) => Promise<void>
  readonly get: (workspaceId: string) => Promise<SavedProjectWork | undefined>
  readonly remove: (workspaceId: string) => Promise<void>
}

export type KeptWork = Pick<Sandbox, "hasSavedWork" | "workLost"> & KeptChats

const decodeWork = Schema.decodeUnknownSync(SavedProjectWork)

export const makeSavedWorkStore = (dataDir: string): SavedWorkStore => {
  const folder = join(dataDir, "sandbox-saved-work")
  const fileOf = (workspaceId: string): string => join(folder, `${workspaceId.toLowerCase()}.json`)
  return {
    put: async (workspaceId, work) => {
      await mkdir(folder, { recursive: true })
      await writeFile(fileOf(workspaceId), JSON.stringify(work), { mode: 0o600 })
    },
    get: async (workspaceId) => {
      const raw = await readFile(fileOf(workspaceId), "utf8").catch(() => undefined)
      return raw === undefined ? undefined : decodeWork(JSON.parse(raw))
    },
    remove: (workspaceId) => rm(fileOf(workspaceId), { force: true })
  }
}

type ArchivedMachine = Sandbox & { readonly providerMachineId: string }

export const keepWork = async (
  deps: SandboxDeps,
  provider: SandboxProvider,
  machine: ArchivedMachine,
  workspaceId: string
): Promise<KeptWork> => {
  try {
    const remote = sandboxRemote(provider, machine.providerMachineId)
    const saved = await remote.request("POST", savedWorkPath(machine.remoteProjectId))
    await deps.savedWork.put(workspaceId, decodeWork(saved))
    return { hasSavedWork: true }
  } catch (cause) {
    const workLost = `Its branch and unpushed work couldn't be saved when it was archived: ${messageOf(cause)}`
    deps.log(`Sandbox ${machine.name} (${machine.id}): ${workLost}`)
    return { workLost }
  }
}

export const keptWorkOf = (machine: Sandbox): KeptWork => ({
  ...(machine.hasSavedWork === true ? { hasSavedWork: true } : {}),
  ...(machine.workLost === undefined ? {} : { workLost: machine.workLost }),
  ...keptChatsOf(machine)
})

export const startsOnNewBranch = (machine: Sandbox): boolean =>
  machine.restoresWorkspace !== true || machine.hasSavedWork !== true

export interface WorkDestination {
  readonly remote: SandboxRemote
  readonly setup: SandboxSetupProgress
  readonly remoteProjectId: string
}

export const bringBackWork = async (
  deps: SandboxDeps,
  machine: Sandbox,
  { remote, setup, remoteProjectId }: WorkDestination
): Promise<void> => {
  if (machine.restoresWorkspace !== true || machine.workspaceId === undefined) return
  if (machine.hasSavedWork !== true) {
    setup.log(`${notKept} ${machine.workLost ?? archivedBeforeWorkWasKept}`)
    return
  }
  const work = await deps.savedWork.get(machine.workspaceId)
  if (work === undefined) {
    throw new Error(
      `The work ${machine.name} had before it was archived isn't on this Mac. Restore it from the Mac that archived it.`
    )
  }
  await remote.request("PUT", savedWorkPath(remoteProjectId), work)
  setup.log(`Brought back ${work.branch ?? "its detached checkout"} with its unpushed work`)
}

export const forgetBroughtBackWork = async (deps: SandboxDeps, machine: Sandbox): Promise<void> => {
  if (machine.restoresWorkspace !== true || machine.workspaceId === undefined) return

  await deps.savedWork.remove(machine.workspaceId)
  await forgetBroughtBackChats(deps, machine)
}

const notKept = "Its earlier branch and unpushed work weren't kept, so it starts on a new branch."

const archivedBeforeWorkWasKept = "It was archived before Codevisor kept a sandbox's work."

const savedWorkPath = (remoteProjectId: string | undefined): string => {
  if (remoteProjectId === undefined) throw new Error("the sandbox didn't say where its project is")
  return `/v1/projects/${remoteProjectId}/saved-work`
}

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
