import { randomUUID } from "node:crypto"

import { CommandExitError, NotFoundError, Sandbox, type SandboxInfo } from "e2b"

import { shellQuote } from "./bootstrap.js"
import type { E2bClient, E2bSandboxInfo } from "./e2b.js"
import type { ExecResult } from "./provider.js"

export const e2bSdkClient = (apiKey: string): E2bClient => ({
  create: async (template, options) => {
    const sandbox = await Sandbox.create(template, { apiKey, ...options })
    return sandboxInfo(await sandbox.getInfo())
  },
  runAsRoot: async (sandboxId, script, options) => {
    const sandbox = await Sandbox.connect(sandboxId, { apiKey })
    const command = await withStdinFile(sandbox, script, options.stdin)
    return runCommand(sandbox, command, options.timeoutMs)
  },
  info: async (sandboxId) => {
    try {
      return sandboxInfo(await Sandbox.getInfo(sandboxId, { apiKey }))
    } catch (cause) {
      if (cause instanceof NotFoundError) return undefined
      throw cause
    }
  },
  kill: async (sandboxId) => {
    await Sandbox.kill(sandboxId, { apiKey })
  },
  list: async (metadata) => {
    const paginator = Sandbox.list({ apiKey, query: { metadata } })
    const sandboxes: E2bSandboxInfo[] = []
    while (paginator.hasNext) sandboxes.push(...(await paginator.nextItems()).map(sandboxInfo))
    return sandboxes
  }
})

const sandboxInfo = (info: SandboxInfo): E2bSandboxInfo => ({
  sandboxId: info.sandboxId,
  endAt: info.endAt,
  metadata: info.metadata
})

const withStdinFile = async (
  sandbox: Sandbox,
  script: string,
  stdin: string | undefined
): Promise<string> => {
  const scriptCommand = `sh -c ${shellQuote(script)}`
  if (stdin === undefined) return `${scriptCommand} </dev/null`

  const path = `/tmp/codevisor-stdin-${randomUUID()}`
  await sandbox.files.write(path, stdin, { user: "root" })
  return `${scriptCommand} <${path}; status=$?; rm -f ${path}; exit $status`
}

const runCommand = async (
  sandbox: Sandbox,
  command: string,
  timeoutMs: number
): Promise<ExecResult> => {
  try {
    const result = await sandbox.commands.run(command, { user: "root", timeoutMs })
    return { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr }
  } catch (cause) {
    if (cause instanceof CommandExitError) {
      return { exitCode: cause.exitCode, stdout: cause.stdout, stderr: cause.stderr }
    }
    throw cause
  }
}
