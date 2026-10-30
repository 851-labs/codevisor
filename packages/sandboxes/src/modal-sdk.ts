import { ModalClient as Modal, NotFoundError, type Image, type Sandbox } from "modal"

import {
  MODAL_APP_NAME,
  type ModalClient,
  type ModalCreateRequest,
  type ModalSandboxRef
} from "./modal.js"
import type { ExecResult } from "./provider.js"

export interface ModalCredentials {
  readonly tokenId: string
  readonly tokenSecret: string
}

export const modalSdkClient = (credentials: ModalCredentials): ModalClient => {
  const modal = new Modal(credentials)
  const app = () => modal.apps.fromName(MODAL_APP_NAME, { createIfMissing: true })
  const lookup = async (sandboxId: string): Promise<Sandbox | undefined> => {
    try {
      return await modal.sandboxes.fromId(sandboxId)
    } catch (cause) {
      if (cause instanceof NotFoundError) return undefined
      throw cause
    }
  }
  return {
    create: async (request) => {
      const image = await imageFor(modal, request)
      const sandbox = await modal.sandboxes.create(await app(), image, {
        cpu: request.cpu,
        memoryMiB: request.memoryMiB,
        timeoutMs: request.timeoutMs,
        tags: request.tags
      })
      return sandbox.sandboxId
    },
    exec: async (sandboxId, script, options) => {
      const sandbox = await modal.sandboxes.fromId(sandboxId)
      return runScript(sandbox, script, options)
    },
    isRunning: async (sandboxId) => {
      const sandbox = await lookup(sandboxId)
      if (sandbox === undefined) return undefined
      return (await sandbox.poll()) === null
    },
    terminate: async (sandboxId) => {
      await (await lookup(sandboxId))?.terminate({ wait: true })
    },
    list: async (tags) => {
      const sandboxes: ModalSandboxRef[] = []
      const { appId } = await app()
      for await (const sandbox of modal.sandboxes.list({ appId, tags })) {
        sandboxes.push({ sandboxId: sandbox.sandboxId, tags: await sandbox.getTags() })
      }
      return sandboxes
    },
    snapshot: async (sandboxId) => {
      const sandbox = await modal.sandboxes.fromId(sandboxId)
      return (await sandbox.snapshotFilesystem({ timeoutMs: snapshotTimeoutMs })).imageId
    }
  }
}

const snapshotTimeoutMs = 10 * 60 * 1000

const imageFor = async (modal: Modal, request: ModalCreateRequest): Promise<Image> => {
  if (request.snapshot !== undefined) return modal.images.fromId(request.snapshot)

  return modal.images.fromRegistry(request.image).dockerfileCommands([...request.setupCommands])
}

const runScript = async (
  sandbox: Sandbox,
  script: string,
  options: { readonly stdin?: string; readonly timeoutMs: number }
): Promise<ExecResult> => {
  const process = await sandbox.exec(["sh", "-c", script], {
    stdout: "pipe",
    stderr: "pipe",
    timeoutMs: options.timeoutMs
  })
  if (options.stdin !== undefined) await process.stdin.writeText(options.stdin)
  await process.stdin.close()
  const [stdout, stderr, exitCode] = await Promise.all([
    process.stdout.readText(),
    process.stderr.readText(),
    process.wait()
  ])
  return { exitCode, stdout, stderr }
}
