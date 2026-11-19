import { mkdir, open, readdir, stat } from "node:fs/promises"
import { dirname, join, relative } from "node:path"

import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { SavedChatResume, SessionSummary } from "@codevisor/api"

import { HttpFailure, type CodevisorServerServices } from "../server-context.js"
import { writeAt } from "./bot-import-files.js"
import { isSafeRelativePath } from "./project-setup-source.js"

type AccountEnvironment = Readonly<Record<string, string>> | undefined

export interface ResumeHost {
  readonly auth:
    | Pick<NonNullable<CodevisorServerServices["auth"]>, "accountContext" | "activeAccountContext">
    | undefined
  readonly home: string
}

interface ResumeStore {
  readonly rootOf: (home: string, environment: AccountEnvironment) => string
  readonly needsAccount: boolean
  readonly belongsTo: (path: string, agentSessionId: string) => boolean
}

const resumeStores: Readonly<Record<string, ResumeStore | undefined>> = {
  "claude-code": {
    rootOf: (home, environment) =>
      join(environment?.["CLAUDE_CONFIG_DIR"] ?? join(home, ".claude"), "projects"),
    needsAccount: false,
    belongsTo: (path, agentSessionId) => {
      const [, name, ...nested] = path.split("/")
      if (nested.length === 0) return name === `${agentSessionId}.jsonl`
      return name === agentSessionId
    }
  },
  codex: {
    rootOf: (home, environment) =>
      join(environment?.["CODEX_HOME"] ?? join(home, ".codex"), "sessions"),
    needsAccount: true,
    belongsTo: (path, agentSessionId) => path.endsWith(`-${agentSessionId}.jsonl`)
  }
}

export const savedResumeOf = async (
  host: ResumeHost,
  session: SessionSummary
): Promise<SavedChatResume | undefined> => {
  const { agentSessionId } = session
  const store = resumeStores[session.harnessId]
  if (store === undefined || agentSessionId === undefined || agentSessionId === "") return undefined
  const root = await sessionRoot(host, store, session)
  if (root === undefined) return undefined

  const files: Array<SavedChatResume["files"][number]> = []
  for (const path of await filesUnder(root)) {
    if (!store.belongsTo(path, agentSessionId)) continue
    files.push({ path, sizeBytes: (await stat(join(root, path))).size })
  }
  return files.length === 0 ? undefined : { agentSessionId, files }
}

export const readResumeFile = async (
  host: ResumeHost,
  session: SessionSummary,
  chunk: { readonly path: string; readonly offset: number; readonly length: number }
): Promise<{ readonly data: string }> => {
  const store = resumeStores[session.harnessId]
  const missing = new HttpFailure(404, `No saved agent session file: ${chunk.path}`)
  if (store === undefined || !isSafeRelativePath(chunk.path)) throw missing
  if (!store.belongsTo(chunk.path, session.agentSessionId ?? "")) throw missing
  const root = await sessionRoot(host, store, session)
  if (root === undefined) throw missing

  const handle = await open(join(root, chunk.path), "r")
  try {
    const read = await handle.read(Buffer.alloc(chunk.length), 0, chunk.length, chunk.offset)
    return { data: read.buffer.subarray(0, read.bytesRead).toString("base64") }
  } finally {
    await handle.close()
  }
}

export const writeResumeFile = async (
  host: ResumeHost,
  chunk: {
    readonly harnessId: string
    readonly path: string
    readonly offset: number
    readonly data: string
  }
): Promise<{ readonly accountId?: string }> => {
  const store = resumeStores[chunk.harnessId]
  if (store === undefined || !isSafeRelativePath(chunk.path)) {
    throw new HttpFailure(422, `This sandbox can't place an agent session file at ${chunk.path}`)
  }
  const account = await host.auth?.activeAccountContext(chunk.harnessId)
  if (store.needsAccount && account === undefined) {
    throw new HttpFailure(409, `${chunk.harnessId} isn't signed in on this sandbox yet`)
  }
  const target = join(store.rootOf(host.home, account?.env), chunk.path)
  const bytes = Buffer.from(chunk.data, "base64")
  await mkdir(dirname(target), { recursive: true, mode: 0o700 })
  await writeAt(target, chunk.offset, bytes, 0o600)
  return account === undefined || !store.needsAccount ? {} : { accountId: account.id }
}

const sessionRoot = async (
  host: ResumeHost,
  store: ResumeStore,
  session: SessionSummary
): Promise<string | undefined> => {
  const account = await sessionAccount(host, session)
  if (store.needsAccount && account === undefined) return undefined
  return store.rootOf(host.home, account?.env)
}

const sessionAccount = async (
  host: ResumeHost,
  { harnessAccountId }: SessionSummary
): Promise<HarnessAccountContext | undefined> => {
  if (harnessAccountId === undefined) return undefined
  return host.auth?.accountContext(harnessAccountId).catch(() => undefined)
}

const filesUnder = async (root: string): Promise<ReadonlyArray<string>> => {
  const entries = await readdir(root, { recursive: true, withFileTypes: true }).catch(() => [])
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => relative(root, join(entry.parentPath, entry.name)))
    .toSorted()
}
