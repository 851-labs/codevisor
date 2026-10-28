import { Readable } from "node:stream"

import { APIError, Sandbox } from "@vercel/sandbox"

import type { ExecResult } from "./provider.js"
import type {
  VercelAccount,
  VercelClient,
  VercelCredentials,
  VercelSandboxInfo,
  VercelTeam
} from "./vercel.js"

const apiUrl = "https://api.vercel.com"
const notFoundStatus = 404
const teamsPageSize = 100
const keptSnapshots = { count: 1, deleteEvicted: true }

export const vercelSdkClient = (credentials: VercelCredentials): VercelClient => {
  const lookup = async (name: string): Promise<Sandbox | undefined> => {
    try {
      return await Sandbox.get({ ...credentials, name })
    } catch (cause) {
      if (isNotFound(cause)) return undefined
      throw cause
    }
  }
  return {
    create: async (request) => {
      const sandbox = await Sandbox.create({
        ...credentials,
        image: request.image,
        resources: { vcpus: request.vcpus },
        timeout: request.timeoutMs,
        tags: request.tags,
        persistent: true,
        keepLastSnapshots: keptSnapshots
      })
      return sandboxInfo(sandbox)
    },
    runAsRoot: async (name, script, options) => {
      const sandbox = await Sandbox.get({ ...credentials, name })
      return runScript(sandbox, script, options)
    },
    info: async (name) => {
      const sandbox = await lookup(name)
      return sandbox === undefined ? undefined : sandboxInfo(sandbox)
    },
    resume: async (name) => {
      await Sandbox.get({ ...credentials, name, resume: true })
    },
    remove: async (name) => {
      await (await lookup(name))?.delete({ deleteOrphanSnapshots: true })
    },
    list: async (tags) => {
      const sandboxes = await (await Sandbox.list({ ...credentials, tags })).toArray()
      return sandboxes.map(listedInfo)
    }
  }
}

export const vercelAccountApi = (token: string): VercelAccount => {
  const send = (path: string, init: RequestInit = {}): Promise<Response> =>
    fetch(`${apiUrl}${path}`, {
      ...init,
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }
    })
  const json = async (path: string, init?: RequestInit): Promise<unknown> =>
    bodyOf(await send(path, init))
  return {
    user: async () => {
      const user = fieldOf(await json("/v2/user"), "user")
      const email = fieldOf(user, "email")
      const defaultTeamId = fieldOf(user, "defaultTeamId")
      return {
        ...(typeof email === "string" ? { email } : {}),
        ...(typeof defaultTeamId === "string" ? { defaultTeamId } : {})
      }
    },
    teams: async () => {
      const teams: VercelTeam[] = []
      let until: unknown = undefined
      do {
        const page = await json(`/v2/teams?limit=${teamsPageSize}${untilParam(until)}`)
        teams.push(...arrayOf(fieldOf(page, "teams")).flatMap(teamOf))
        until = fieldOf(fieldOf(page, "pagination"), "next")
      } while (typeof until === "number")
      return teams
    },
    project: async (teamId, name) => {
      const team = `teamId=${encodeURIComponent(teamId)}`
      const existing = await send(`/v9/projects/${encodeURIComponent(name)}?${team}`)
      let project = await bodyOf(existing, notFoundStatus)
      if (existing.status === notFoundStatus) {
        project = await json(`/v11/projects?${team}`, {
          method: "POST",
          body: JSON.stringify({ name })
        })
      }
      const id = fieldOf(project, "id")
      if (typeof id !== "string") throw new Error(`Vercel didn't return the ${name} project`)
      return id
    }
  }
}

const runScript = async (
  sandbox: Sandbox,
  script: string,
  options: { readonly stdin?: string; readonly timeoutMs: number }
): Promise<ExecResult> => {
  const finished = await sandbox.runCommand({
    cmd: "sh",
    args: ["-c", script],
    sudo: true,
    timeoutMs: options.timeoutMs,
    ...stdinStream(options.stdin)
  })
  const [stdout, stderr] = await Promise.all([finished.stdout(), finished.stderr()])
  return { exitCode: finished.exitCode, stdout, stderr }
}

const stdinStream = (stdin: string | undefined): { readonly stdin?: Readable } =>
  stdin === undefined ? {} : { stdin: Readable.from([Buffer.from(stdin)]) }

const sandboxInfo = (sandbox: Sandbox): VercelSandboxInfo => ({
  name: sandbox.name,
  status: sandbox.status,
  tags: sandbox.tags ?? {},
  ...(sandbox.expiresAt === undefined ? {} : { expiresAt: sandbox.expiresAt })
})

interface ListedSandbox {
  readonly name: string
  readonly status: string
  readonly expiresAt?: number | undefined
  readonly tags?: Record<string, string> | undefined
}

const listedInfo = (sandbox: ListedSandbox): VercelSandboxInfo => ({
  name: sandbox.name,
  status: sandbox.status,
  tags: sandbox.tags ?? {},
  ...(sandbox.expiresAt === undefined ? {} : { expiresAt: new Date(sandbox.expiresAt) })
})

const isNotFound = (cause: unknown): boolean =>
  cause instanceof APIError && cause.response.status === notFoundStatus

const bodyOf = async (response: Response, allowed?: number): Promise<unknown> => {
  const body: unknown = await response.json().catch(() => undefined)
  if (response.ok || response.status === allowed) return body

  const message = fieldOf(fieldOf(body, "error"), "message")
  throw new Error(typeof message === "string" ? message : `Vercel answered ${response.status}`)
}

const teamOf = (team: unknown): ReadonlyArray<VercelTeam> => {
  const id = fieldOf(team, "id")
  if (typeof id !== "string") return []

  const labels = [fieldOf(team, "name"), fieldOf(team, "slug")]
  return [{ id, name: labels.find((label) => typeof label === "string") ?? id }]
}

const untilParam = (until: unknown): string => (typeof until === "number" ? `&until=${until}` : "")

const arrayOf = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

const fieldOf = (value: unknown, key: string): unknown =>
  typeof value === "object" && value !== null ? Reflect.get(value, key) : undefined
