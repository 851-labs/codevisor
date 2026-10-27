import { spawnSync } from "node:child_process"
import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { setTimeout as delay } from "node:timers/promises"

import { CloudApiError, rewriteMachineInviteServer } from "@codevisor/cloud-client"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { loadEncryptionKey } from "@codevisor/mcp"
import {
  e2bSdkClient,
  makeE2bProvider,
  makeModalProvider,
  makeTartProvider,
  modalSdkClient,
  tartCliHost,
  type SandboxProvider,
  type SandboxProviderId,
  type TartImages
} from "@codevisor/sandboxes"
import type { BlobStore } from "@codevisor/sync"

import type { MachineEnrollment } from "./infra/machine-enrollment.js"
import type { MachineLink } from "./infra/machine-link.js"
import { FIRST_AGENT_WAIT, pushRemainingAgents } from "./infra/sandbox-agents.js"
import {
  makeSandboxCredentialStore,
  type ProviderCredentials
} from "./infra/sandbox-credentials.js"
import {
  appBundleOf,
  STABLE_SERVER_MANIFEST_URL,
  tartImages,
  type TartImageSettings
} from "./infra/sandbox-image.js"
import { makeSandboxRecordStore } from "./infra/sandbox-store.js"
import { pushOneWaySync } from "./infra/sandbox-sync.js"
import { configuredProviderIds, makeSandboxes } from "./infra/sandboxes.js"
import type { SandboxesService } from "./routes/sandboxes.js"
import type { CloudServerControl } from "./server-context-types.js"
import { HttpFailure, run } from "./server-context.js"

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
  const credentials = makeSandboxCredentialStore(options.db, () =>
    loadEncryptionKey(options.dataDir)
  )
  const records = makeSandboxRecordStore(options.db)
  const tartBinary = options.env["CODEVISOR_TART_PATH"] ?? "tart"
  const images = tartImages(imageSettings(options.env))
  const machines = makeSandboxes({
    records,
    providers: {
      get: async (id) => providerFor(id, await credentials.read(id), { tartBinary, images }),
      configured: async () =>
        (await configuredProviderIds(credentials.isConfigured)).filter(
          (id) => id !== "tart" || tartAvailable(tartBinary)
        )
    },
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
    projects: {
      get: async (projectId) =>
        (await run(options.db.listProjects)).find(
          (project) => project.id.toLowerCase() === projectId.toLowerCase()
        )
    },
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
  const tick = (): void => {
    void machines
      .sweep()
      .then(() => machines.watch())
      .catch((cause: unknown) => console.log(`Sandbox check failed: ${String(cause)}`))
  }
  return {
    machines,
    credentials,
    records,
    start: () => {
      tick()
      setInterval(tick, watchIntervalMs).unref()
    }
  }
}

interface TartSettings {
  readonly tartBinary: string
  readonly images: TartImages
}

const providerFor = (
  id: SandboxProviderId,
  credentials: ProviderCredentials | undefined,
  tart: TartSettings
): SandboxProvider => {
  if (credentials === undefined) {
    throw new HttpFailure(409, `Add your ${id} credentials before creating a sandbox`)
  }
  if (id === "e2b") return makeE2bProvider(e2bSdkClient(credentials["apiKey"] ?? ""))
  if (id === "modal") {
    return makeModalProvider(
      modalSdkClient({
        tokenId: credentials["tokenId"] ?? "",
        tokenSecret: credentials["tokenSecret"] ?? ""
      })
    )
  }
  return makeTartProvider(tartCliHost(tart.tartBinary), tart.images)
}

const tartAvailable = (binary: string): boolean =>
  process.platform === "darwin" &&
  spawnSync(binary, ["--version"], { stdio: "ignore" }).status === 0

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
