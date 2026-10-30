import type { SyncEntryRecord } from "@codevisor/sync"

import { run } from "../server-context.js"
import type { SandboxRemote } from "./sandbox-remote.js"
import { HARNESSES_NAMESPACE, type OneWaySyncSource } from "./sandbox-sync.js"

export interface AgentWait {
  readonly sleep: (ms: number) => Promise<void>
  readonly attempts: number
  readonly intervalMs: number
}

export const FIRST_AGENT_WAIT = { attempts: 150, intervalMs: 2000 }
export const NEXT_AGENT_ATTEMPTS = 45

export interface AgentOrder {
  readonly first: string
  readonly chosen: () => string | undefined
}

export const pushRemainingAgents = async (
  source: OneWaySyncSource,
  remote: SandboxRemote,
  order: AgentOrder,
  wait: AgentWait
): Promise<void> => {
  const queue = agentQueue(await run(source.db.getSyncEntries(HARNESSES_NAMESPACE)), order)
  await waitForAgent(remote, order.first, wait, queue.chosenWaits)
  for (let next = queue.next(); next !== undefined; next = queue.next()) {
    await installOnRemote(remote, queue.push(next))
    if (wantsInstall(next))
      await waitForAgent(remote, next.key, waitFor(next, order, wait), queue.chosenWaits)
  }
}

interface AgentQueue {
  readonly next: () => SyncEntryRecord | undefined
  readonly push: (entry: SyncEntryRecord) => ReadonlyArray<SyncEntryRecord>
  readonly chosenWaits: () => boolean
}

const agentQueue = (entries: ReadonlyArray<SyncEntryRecord>, order: AgentOrder): AgentQueue => {
  const pushed = entries.filter((entry) => entry.key === order.first)
  const remaining = () => entries.filter((entry) => !pushed.includes(entry))
  return {
    next: () => remaining().find((entry) => entry.key === order.chosen()) ?? remaining()[0],
    push: (entry) => {
      pushed.push(entry)
      return pushed
    },
    chosenWaits: () => remaining().some((entry) => entry.key === order.chosen())
  }
}

const waitFor = (entry: SyncEntryRecord, order: AgentOrder, wait: AgentWait): AgentWait =>
  entry.key === order.chosen() ? wait : { ...wait, attempts: NEXT_AGENT_ATTEMPTS }

const installOnRemote = async (
  remote: SandboxRemote,
  entries: ReadonlyArray<SyncEntryRecord>
): Promise<void> => {
  await remote.request("PUT", `/v1/sync/${HARNESSES_NAMESPACE}`, { entries })
  await remote.request("POST", `/v1/sync/${HARNESSES_NAMESPACE}/reconcile`)
}

const wantsInstall = (entry: SyncEntryRecord): boolean =>
  isRecord(entry.value) && entry.value["installed"] === true && entry.value["enabled"] !== false

export const waitForAgent = async (
  remote: SandboxRemote,
  harnessId: string,
  wait: AgentWait,
  interrupted: () => boolean = () => false
): Promise<void> => {
  for (let attempt = 1; attempt <= wait.attempts; attempt += 1) {
    if (interrupted()) return
    const harnesses = await remote.request("GET", "/v1/harnesses").catch(() => [])
    if (isReady(harnesses, harnessId)) return
    await wait.sleep(wait.intervalMs)
  }
}

const isReady = (harnesses: unknown, harnessId: string): boolean =>
  Array.isArray(harnesses) &&
  harnesses.some(
    (harness: unknown) =>
      isRecord(harness) &&
      harness["id"] === harnessId &&
      isRecord(harness["readiness"]) &&
      harness["readiness"]["state"] === "ready"
  )

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null
