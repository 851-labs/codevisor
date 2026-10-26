import { spawnSync } from "node:child_process"
import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { setTimeout as delay } from "node:timers/promises"

import { CloudApiError, rewriteMachineInviteServer } from "@codevisor/cloud-client"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  e2bSdkClient,
  makeE2bProvider,
  makeModalProvider,
  makeTartProvider,
  modalSdkClient,
  tartCliHost,
  type EphemeralProvider,
  type EphemeralProviderId
} from "@codevisor/ephemeral-machines"
import { loadEncryptionKey } from "@codevisor/mcp"
import type { BlobStore } from "@codevisor/sync"

import {
  makeEphemeralCredentialStore,
  type ProviderCredentials
} from "./infra/ephemeral-credentials.js"
import { configuredProviderIds, makeEphemeralMachines } from "./infra/ephemeral-machines.js"
import { makeEphemeralRecordStore } from "./infra/ephemeral-store.js"
import { pushOneWaySync } from "./infra/ephemeral-sync.js"
import type { MachineEnrollment } from "./infra/machine-enrollment.js"
import type { MachineLink } from "./infra/machine-link.js"
import type { EphemeralMachinesService } from "./routes/ephemeral-machines.js"
import type { CloudServerControl } from "./server-context-types.js"
import { HttpFailure, run } from "./server-context.js"

const watchIntervalMs = 30 * 1000

export interface EphemeralBootOptions {
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

export const startEphemeralMachines = (
  options: EphemeralBootOptions
): EphemeralMachinesService & { readonly start: () => void } => {
  const credentials = makeEphemeralCredentialStore(options.db, () =>
    loadEncryptionKey(options.dataDir)
  )
  const records = makeEphemeralRecordStore(options.db)
  const tartBinary = options.env["CODEVISOR_TART_PATH"] ?? "tart"
  const machines = makeEphemeralMachines({
    records,
    providers: {
      get: async (id) => providerFor(id, await credentials.read(id), tartBinary),
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
    sync: (remote) => pushOneWaySync({ db: options.db, blobs: options.syncBlobs }, remote),
    bootstrap: bootstrapSettings(options.env),
    clock: { now: Date.now, sleep: (ms) => delay(ms) },
    newId: randomUUID,
    log: (line) => console.log(line)
  })
  const tick = (): void => {
    void machines
      .sweep()
      .then(() => machines.watch())
      .catch((cause: unknown) => console.log(`Ephemeral machine check failed: ${String(cause)}`))
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

const providerFor = (
  id: EphemeralProviderId,
  credentials: ProviderCredentials | undefined,
  tartBinary: string
): EphemeralProvider => {
  if (credentials === undefined) {
    throw new HttpFailure(409, `Add your ${id} credentials before creating an ephemeral machine`)
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
  return makeTartProvider(tartCliHost(tartBinary))
}

const tartAvailable = (binary: string): boolean =>
  process.platform === "darwin" &&
  spawnSync(binary, ["--version"], { stdio: "ignore" }).status === 0

const inviteFor = async (
  options: EphemeralBootOptions,
  provider: EphemeralProviderId
): Promise<string> => {
  const { code } = await options.enrollment.invite({ ephemeral: { provider } })
  const cloudUrl = options.env["CODEVISOR_EPHEMERAL_CLOUD_URL"]
  return cloudUrl === undefined ? code : rewriteMachineInviteServer(code, cloudUrl)
}

const removeQuietly = async (options: EphemeralBootOptions, deviceId: string): Promise<void> => {
  try {
    await options.cloud.removePeer(deviceId)
  } catch (cause) {
    if (cause instanceof CloudApiError && cause.status === 404) return
    throw cause
  }
}

const bootstrapSettings = (env: NodeJS.ProcessEnv) => ({
  ...(env["CODEVISOR_INSTALL_URL"] === undefined
    ? {}
    : { installUrl: env["CODEVISOR_INSTALL_URL"] }),
  serverEnvironment: developmentServerEnvironment(env)
})

const developmentServerEnvironment = (env: NodeJS.ProcessEnv): Record<string, string> => {
  const caFile = env["CODEVISOR_NET_CA_FILE"]
  const instance = env["CODEVISOR_DEV_INSTANCE_ID"]
  return {
    ...(caFile === undefined ? {} : { CODEVISOR_NET_CA_PEM: readFileSync(caFile, "utf8") }),
    ...(instance === undefined ? {} : { CODEVISOR_DEV_INSTANCE_ID: `${instance}-ephemeral` })
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
