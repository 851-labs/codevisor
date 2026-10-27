import { run } from "../server-context.js"
import type { SandboxRemote } from "./sandbox-remote.js"
import { HARNESSES_NAMESPACE, type OneWaySyncSource } from "./sandbox-sync.js"

export interface AgentWait {
  readonly sleep: (ms: number) => Promise<void>
  readonly attempts: number
  readonly intervalMs: number
}

export const FIRST_AGENT_WAIT = { attempts: 150, intervalMs: 2000 }

export const pushRemainingAgents = async (
  source: OneWaySyncSource,
  remote: SandboxRemote,
  firstHarness: string,
  wait: AgentWait
): Promise<void> => {
  await waitForAgent(remote, firstHarness, wait)
  const entries = await run(source.db.getSyncEntries(HARNESSES_NAMESPACE))
  await remote.request("PUT", `/v1/sync/${HARNESSES_NAMESPACE}`, { entries })
  await remote.request("POST", `/v1/sync/${HARNESSES_NAMESPACE}/reconcile`)
}

const waitForAgent = async (
  remote: SandboxRemote,
  harnessId: string,
  wait: AgentWait
): Promise<void> => {
  for (let attempt = 1; attempt <= wait.attempts; attempt += 1) {
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
