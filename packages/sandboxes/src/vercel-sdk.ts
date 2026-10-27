import { Readable } from "node:stream"

import { APIError, Sandbox } from "@vercel/sandbox"

import type { ExecResult } from "./provider.js"
import type { VercelClient, VercelCredentials, VercelSandboxInfo } from "./vercel.js"

const userUrl = "https://api.vercel.com/v2/user"
const notFoundStatus = 404
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
    },
    email: () => userEmail(credentials.token)
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

const userEmail = async (token: string): Promise<string | undefined> => {
  const response = await fetch(userUrl, { headers: { authorization: `Bearer ${token}` } })
  if (!response.ok) return undefined

  const body: unknown = await response.json()
  const email = fieldOf(fieldOf(body, "user"), "email")
  return typeof email === "string" ? email : undefined
}

const fieldOf = (value: unknown, key: string): unknown =>
  typeof value === "object" && value !== null ? Reflect.get(value, key) : undefined
