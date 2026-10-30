import { randomUUID } from "node:crypto"
import { setTimeout as sleep } from "node:timers/promises"

import { Daytona, DaytonaNotFoundError, Image, type Sandbox } from "@daytona/sdk"

import type {
  DaytonaClient,
  DaytonaCreateRequest,
  DaytonaCredentials,
  DaytonaSandboxInfo
} from "./daytona.js"
import type { ExecResult } from "./provider.js"

const createTimeoutSeconds = 15 * 60
const startTimeoutSeconds = 10 * 60
const pollIntervalMs = 1000
const pollGraceMs = 60 * 1000

export const daytonaSdkClient = (credentials: DaytonaCredentials): DaytonaClient => {
  const daytona = new Daytona(credentials)
  const lookup = async (sandboxId: string): Promise<Sandbox | undefined> => {
    try {
      return await daytona.get(sandboxId)
    } catch (cause) {
      if (cause instanceof DaytonaNotFoundError) return undefined
      throw cause
    }
  }
  return {
    create: async (request, onLog) => sandboxInfo(await createSandbox(daytona, request, onLog)),
    upload: async (sandboxId, path, content) => {
      const sandbox = await daytona.get(sandboxId)
      await sandbox.fs.uploadFile(Buffer.from(content), path)
    },
    run: async (sandboxId, command, timeoutMs) =>
      runInSession(await daytona.get(sandboxId), command, timeoutMs),
    info: async (sandboxId) => {
      const sandbox = await lookup(sandboxId)
      return sandbox === undefined ? undefined : sandboxInfo(sandbox)
    },
    start: async (sandboxId) => {
      const sandbox = await daytona.get(sandboxId)
      await sandbox.start(startTimeoutSeconds)
    },
    stop: async (sandboxId) => {
      await daytona.stop(await daytona.get(sandboxId))
    },
    remove: async (sandboxId) => {
      await (await lookup(sandboxId))?.delete()
    },
    list: async (labels) => {
      const sandboxes: DaytonaSandboxInfo[] = []
      for await (const sandbox of daytona.list({ labels })) sandboxes.push(sandboxInfo(sandbox))
      return sandboxes
    },
    email: () => userEmail(credentials)
  }
}

const createSandbox = (
  daytona: Daytona,
  request: DaytonaCreateRequest,
  onLog: (line: string) => void
): Promise<Sandbox> => {
  const lifecycle = {
    labels: request.labels,
    autoStopInterval: request.autoStopMinutes
  }
  const { source } = request
  if (source.kind === "snapshot") {
    return daytona.create(
      { ...lifecycle, snapshot: source.snapshot },
      { timeout: createTimeoutSeconds }
    )
  }
  return daytona.create(
    {
      ...lifecycle,
      image: Image.base(source.image).runCommands(...source.setupCommands),
      resources: { ...source.resources }
    },
    { timeout: createTimeoutSeconds, onSnapshotCreateLogs: onLog }
  )
}

const runInSession = async (
  sandbox: Sandbox,
  command: string,
  timeoutMs: number
): Promise<ExecResult> => {
  const sessionId = `codevisor-${randomUUID()}`
  await sandbox.process.createSession(sessionId)
  try {
    const { cmdId } = await sandbox.process.executeSessionCommand(sessionId, {
      command,
      runAsync: true
    })
    const exitCode = await exitCodeOf(
      sandbox,
      sessionId,
      cmdId,
      Date.now() + timeoutMs + pollGraceMs
    )
    const logs = await sandbox.process.getSessionCommandLogs(sessionId, cmdId)
    return { exitCode, stdout: logs.stdout ?? "", stderr: logs.stderr ?? "" }
  } finally {
    await sandbox.process.deleteSession(sessionId).catch(() => undefined)
  }
}

const exitCodeOf = async (
  sandbox: Sandbox,
  sessionId: string,
  cmdId: string,
  deadline: number
): Promise<number> => {
  while (Date.now() < deadline) {
    const { exitCode } = await sandbox.process.getSessionCommand(sessionId, cmdId)
    if (exitCode !== undefined && exitCode !== null) return exitCode
    await sleep(pollIntervalMs)
  }
  throw new Error(`The command on Daytona sandbox ${sandbox.id} did not finish in time`)
}

const sandboxInfo = (sandbox: Sandbox): DaytonaSandboxInfo => ({
  id: sandbox.id,
  labels: sandbox.labels,
  ...(sandbox.state === undefined ? {} : { state: sandbox.state })
})

const userEmail = async (credentials: DaytonaCredentials): Promise<string | undefined> => {
  const response = await fetch(`${credentials.apiUrl}/users/me`, {
    headers: { authorization: `Bearer ${credentials.apiKey}` }
  })
  if (!response.ok) return undefined

  const body: unknown = await response.json()
  const email = typeof body === "object" && body !== null ? Reflect.get(body, "email") : undefined
  return typeof email === "string" ? email : undefined
}
