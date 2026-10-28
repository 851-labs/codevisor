import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"

import { CloudApiError, rewriteMachineInviteServer } from "@codevisor/cloud-client"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  daytonaAdapter,
  daytonaSdkClient,
  downloadTart,
  e2bAdapter,
  e2bSdkClient,
  managedTart,
  modalAdapter,
  modalSdkClient,
  systemTart,
  tartAdapter,
  tartCliHost,
  tartOrchardAdapter,
  tartOrchardApiClient,
  vercelAccountApi,
  vercelAdapter,
  vercelSdkClient,
  type SandboxAdapter,
  type SandboxProviderId,
  type TartImages,
  type TartInstall
} from "@codevisor/sandboxes"
import type { BlobStore } from "@codevisor/sync"

import type { MachineEnrollment } from "./infra/machine-enrollment.js"
import type { MachineLink } from "./infra/machine-link.js"
import { FIRST_AGENT_WAIT, pushRemainingAgents } from "./infra/sandbox-agents.js"
import type { SandboxCatalogDeps } from "./infra/sandbox-catalog.js"
import { makeSandboxAdapters, makeSandboxConnections } from "./infra/sandbox-connections.js"
import { sandboxWorkPending } from "./infra/sandbox-feature.js"
import {
  appBundleOf,
  STABLE_SERVER_MANIFEST_URL,
  tartImages,
  type TartImageSettings
} from "./infra/sandbox-image.js"
import { makeSandboxLocalWorkspaces, type SandboxEvents } from "./infra/sandbox-local-workspaces.js"
import { makeSandboxSettings } from "./infra/sandbox-settings.js"
import { makeSandboxRecordStore } from "./infra/sandbox-store.js"
import { pushOneWaySync } from "./infra/sandbox-sync.js"
import { makeSandboxes } from "./infra/sandboxes.js"
import type { SandboxesService } from "./routes/sandboxes.js"
import type { CloudServerControl } from "./server-context-types.js"
import { run } from "./server-context.js"

const watchIntervalMs = 30 * 1000

export interface SandboxBootOptions {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly serverId: string
  readonly machineName: () => string
  readonly cloud: Required<Pick<CloudServerControl, "deviceId" | "machines" | "removePeer">>
  readonly enrollment: MachineEnrollment
  readonly link: MachineLink
  readonly syncBlobs: BlobStore
  readonly env: NodeJS.ProcessEnv
}

export const startSandboxes = (
  options: SandboxBootOptions
): SandboxesService & { readonly start: () => void } => {
  const records = makeSandboxRecordStore(options.db)
  const settings = makeSandboxSettings(options.db, options.serverId)
  const adapters = makeSandboxAdapters(
    sandboxAdapters({
      install: tartInstall(options),
      images: tartImages(imageSettings(options.env))
    }),
    (id) => id !== "tart" || isAppleSilicon()
  )
  const connections = makeSandboxConnections(adapters, settings)
  const events: SandboxEvents = { publish: () => Promise.resolve() }
  const projects = {
    get: async (projectId: string) =>
      (await run(options.db.listProjects)).find(
        (project) => project.id.toLowerCase() === projectId.toLowerCase()
      )
  }
  const machines = makeSandboxes({
    records,
    connections,
    profiles: { get: settings.profile },
    serverId: options.serverId,
    account: {
      ownerDeviceId: options.cloud.deviceId,
      presences: () => options.cloud.machines() ?? [],
      invite: async (provider) => inviteFor(options, provider),
      remove: async (deviceId) => removeQuietly(options, deviceId)
    },
    remoteTools: {
      call: async (machineId, tool, args) =>
        toolJson(
          await options.link.invoke(machineId, tool, args, {
            machineId: options.serverId,
            machineName: options.machineName()
          })
        )
    },
    projects,
    localWorkspaces: makeSandboxLocalWorkspaces(options.db, projects, events),
    sync: (remote, firstHarness) =>
      pushOneWaySync({ db: options.db, blobs: options.syncBlobs }, remote, firstHarness),
    syncDeferred: (remote, firstHarness) =>
      pushRemainingAgents({ db: options.db }, remote, firstHarness, {
        ...FIRST_AGENT_WAIT,
        sleep: (ms) => delay(ms)
      }),
    bootstrap: bootstrapSettings(options.env),
    clock: { now: Date.now, sleep: (ms) => delay(ms) },
    newId: randomUUID,
    log: (line) => console.log(line)
  })
  const check = async (): Promise<void> => {
    if (!(await sandboxWorkPending(options.db, records))) return

    await machines.sweep()
    await machines.watch()
  }
  const tick = (): void => {
    void check().catch((cause: unknown) => console.log(`Sandbox check failed: ${String(cause)}`))
  }
  const catalog: SandboxCatalogDeps = {
    settings,
    adapters,
    connections,
    serverId: options.serverId,
    sandboxesUsing: async (accountId) =>
      (await records.list()).filter((record) => record.accountId === accountId).length,
    newId: randomUUID,
    now: Date.now
  }
  return {
    sandboxes: machines,
    catalog,
    bindEvents: (publish) => {
      events.publish = publish
    },
    start: () => {
      tick()
      setInterval(tick, watchIntervalMs).unref()
    }
  }
}

interface TartSettings {
  readonly install: TartInstall
  readonly images: TartImages
}

const sandboxAdapters = (tart: TartSettings): ReadonlyArray<SandboxAdapter> => [
  tartAdapter(tartCliHost(tart.install), tart.images),
  tartOrchardAdapter(tartOrchardApiClient),
  e2bAdapter(e2bSdkClient),
  modalAdapter(modalSdkClient),
  vercelAdapter(vercelSdkClient, vercelAccountApi),
  daytonaAdapter(daytonaSdkClient)
]

const tartInstall = (options: SandboxBootOptions): TartInstall => {
  const override = options.env["CODEVISOR_TART_PATH"]
  return override === undefined
    ? managedTart(join(options.dataDir, "tools"), downloadTart)
    : systemTart(override)
}

const isAppleSilicon = (): boolean => process.platform === "darwin" && process.arch === "arm64"

const inviteFor = async (
  options: SandboxBootOptions,
  provider: SandboxProviderId
): Promise<string> => {
  const { code } = await options.enrollment.invite({ ephemeral: { provider } })
  const cloudUrl = developmentSettings(options.env)?.cloudUrl
  return cloudUrl === undefined ? code : rewriteMachineInviteServer(code, cloudUrl)
}

const removeQuietly = async (options: SandboxBootOptions, deviceId: string): Promise<void> => {
  try {
    await options.cloud.removePeer(deviceId)
  } catch (cause) {
    if (cause instanceof CloudApiError && cause.status === 404) return
    throw cause
  }
}

interface DevelopmentSandboxSettings {
  readonly instance: string
  readonly artifactsUrl: string | undefined
  readonly cloudUrl: string | undefined
}

const developmentSettings = (env: NodeJS.ProcessEnv): DevelopmentSandboxSettings | undefined => {
  const instance = env["CODEVISOR_DEV_INSTANCE_ID"]
  if (instance === undefined) return undefined

  return {
    instance,
    artifactsUrl: env["CODEVISOR_DEV_EPHEMERAL_ARTIFACTS_URL"],
    cloudUrl: env["CODEVISOR_DEV_EPHEMERAL_CLOUD_URL"]
  }
}

const bootstrapSettings = (env: NodeJS.ProcessEnv) => {
  const development = developmentSettings(env)
  if (development === undefined) return {}

  return {
    ...developmentInstaller(development.artifactsUrl),
    serverEnvironment: developmentServerEnvironment(env, development.instance)
  }
}

const imageSettings = (env: NodeJS.ProcessEnv): TartImageSettings => {
  const appPath = env["CODEVISOR_EPHEMERAL_APP_PATH"] ?? appBundleOf(process.execPath)
  const development = developmentSettings(env)
  if (development?.artifactsUrl === undefined) {
    return { appPath, serverIdentityUrl: STABLE_SERVER_MANIFEST_URL }
  }

  return {
    appPath,
    serverIdentityUrl: `${development.artifactsUrl}/codevisor-server-darwin-arm64.tar.gz.sha256`,
    ...developmentInstaller(development.artifactsUrl),
    developmentInstance: `${development.instance}-sandbox`
  }
}

const developmentInstaller = (artifactsUrl: string | undefined) => {
  if (artifactsUrl === undefined) return {}

  return {
    installUrl: `${artifactsUrl}/install.sh`,
    installEnvironment: { CODEVISOR_SERVER_ARCHIVE_BASE: artifactsUrl, CODEVISOR_VERSION: "dev" }
  }
}

const developmentServerEnvironment = (
  env: NodeJS.ProcessEnv,
  instance: string
): Record<string, string> => {
  const caFile = env["CODEVISOR_NET_CA_FILE"]
  return {
    ...(caFile === undefined ? {} : { CODEVISOR_NET_CA_PEM: readFileSync(caFile, "utf8") }),
    CODEVISOR_DEV_INSTANCE_ID: `${instance}-sandbox`
  }
}

const toolJson = (result: unknown): unknown => {
  const text = mcpText(result)
  if (text === undefined) return result
  try {
    return JSON.parse(text) as unknown
  } catch {
    return text
  }
}

const mcpText = (result: unknown): string | undefined => {
  if (typeof result !== "object" || result === null || !("content" in result)) return undefined
  const [first] = Array.isArray(result.content) ? (result.content as unknown[]) : []
  if (typeof first !== "object" || first === null || !("text" in first)) return undefined
  return typeof first.text === "string" ? first.text : undefined
}
