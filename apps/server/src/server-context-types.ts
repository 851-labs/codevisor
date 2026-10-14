import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type { ScreenSharingRequest } from "@codevisor/api"
import type { EventEnvelope, ServerKind, SessionSummary, UpdateInfo } from "@codevisor/api"
import type { AttachmentStore, CodevisorDatabaseService } from "@codevisor/db"
import type { CredentialSource } from "@codevisor/harness-manager"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import type { HarnessLifecycleManager } from "@codevisor/harness-manager"
import type { McpManager } from "@codevisor/mcp"
import type { NativeMcpManager } from "@codevisor/mcp"
import type { PluginRegistryClient, PluginsManager } from "@codevisor/plugins"
import type { SkillStore } from "@codevisor/skills"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { ServerUpdateChannel } from "@codevisor/updater"
import { Effect, PubSub, Schema } from "effect"

import type { SessionActivityController } from "./infra/active-work-sleep-inhibitor.js"
import type { BrowserProxy } from "./infra/browser-proxy.js"
import type { ClientControlBroker } from "./infra/client-control.js"
import type { SharedAccounts } from "./infra/shared-accounts.js"
import type { RestartCoordinator } from "./restart-drain.js"
import type { Simulators } from "./simulators.js"

export class ServerError extends Schema.TaggedErrorClass<ServerError>()("ServerError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface CodevisorServerAuthConfig {
  readonly requireBearerToken: boolean
  readonly allowLocalhostWithoutAuth: boolean
}

export interface CodevisorServerUpdater {
  readonly check: (options?: {
    readonly force?: boolean
    readonly channel?: ServerUpdateChannel
  }) => Promise<UpdateInfo>
  readonly apply: (options?: { readonly channel?: ServerUpdateChannel }) => Promise<void>
}

export interface CodevisorServerConfig {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly bootId: string
  readonly processId: number
  readonly appOwned: boolean
  readonly buildNumber?: number | undefined
  readonly sourceRevision?: string | undefined
  readonly serviceManaged: boolean
  readonly kind: ServerKind
  readonly host: string
  readonly port: number
  readonly directPathEnabled: boolean
  readonly worktreeNameStyle: "production" | "development"
  readonly auth: CodevisorServerAuthConfig
  readonly onShutdownRequested?: (() => void) | undefined
  readonly updater?: CodevisorServerUpdater | undefined
  readonly restartSnapshotPath?: string | undefined
  readonly restartDrainTimeoutMs?: number | undefined
  readonly screenSharing?: ((request: ScreenSharingRequest) => Promise<unknown>) | undefined
  readonly screenSharingVNC?: ScreenSharingVNCConfig | undefined
  readonly simulators?: Simulators | undefined
  readonly sessionActivity?: SessionActivityController | undefined
  readonly cloudDeviceId?: string | undefined
  readonly cloud?: CloudServerControl | undefined
}

export interface ScreenSharingVNCConfig {
  readonly port: number
  readonly name: string
  readonly desktop?: "xfce"
  readonly defaultWidth?: number
  readonly defaultHeight?: number
}

export interface CloudServerControl {
  readonly deviceId: () => string | undefined
  readonly state: () => string | undefined
  readonly serverUrl?: () => string | undefined
  readonly managedBy: () => "app" | "external" | undefined
  readonly machineName?: () => string | undefined
  readonly connect: (
    serverUrl: string,
    sessionToken: string,
    options?: { readonly managedBy?: "app" | "external"; readonly machineName?: string }
  ) => Promise<string>
  readonly connectWithInvite?: (
    inviteCode: string,
    options?: { readonly managedBy?: "app" | "external"; readonly machineName?: string }
  ) => Promise<string>
  readonly invite?: () => Promise<import("@codevisor/cloud-client").MachineInvite>
  readonly removePeer?: (deviceId: string) => Promise<void>
  readonly disconnect: () => Promise<{ readonly removedFromAccount: boolean }>
  readonly acceptDirect?: (socket: import("@codevisor/cloud-client").CloudSocket) => boolean
  readonly machines?: () => ReadonlyArray<import("@codevisor/api").CloudMachinePresence> | undefined
  readonly requestGateway?: (
    deviceId: string,
    body: string,
    signal?: AbortSignal
  ) => Promise<import("@codevisor/cloud-client").GatewayExchange>
  readonly bridgeTunnelMedia?: (
    request: import("@codevisor/cloud-client").TunnelMediaRequest,
    answer: string
  ) => Promise<import("@codevisor/cloud-client").TunnelMediaBridge | undefined>
}

export interface CodevisorServerServices {
  readonly db: CodevisorDatabaseService
  readonly attachments: AttachmentStore
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  readonly resolveGitEnvironment?: (directory?: string) => Promise<NodeJS.ProcessEnv>
  readonly auth?: HarnessAuthManager
  readonly sharedAccounts?: SharedAccounts
  readonly credentialFerry?: ReadonlyArray<CredentialSource>
  readonly mcp?: McpManager
  readonly lifecycle?: HarnessLifecycleManager
  readonly nativeMcp?: NativeMcpManager
  readonly skills?: SkillStore
  readonly plugins?: PluginsManager
  readonly pluginRegistry?: PluginRegistryClient
  readonly syncBlobs?: import("@codevisor/sync").BlobStore
  readonly toolIcons?: import("./infra/tool-icons.js").ToolIconStore
  readonly machines?: import("./infra/machine-link.js").MachineLink
  readonly machineEnrollment?: import("./infra/machine-enrollment.js").MachineEnrollment
}

export interface RunningCodevisorServer {
  readonly url: string
  readonly host: string
  readonly port: number
  readonly close: Effect.Effect<void, ServerError>
}

export interface CodevisorServerApp {
  readonly handleConnect: (request: IncomingMessage, socket: Socket, head: Buffer) => void
  readonly handleRequest: (request: IncomingMessage, response: ServerResponse) => void
  readonly handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer) => void
  readonly close: Effect.Effect<void, ServerError>
}

export interface RouteState {
  readonly clientControl?: ClientControlBroker
  readonly browserProxy?: BrowserProxy
  readonly pendingSessionCreates: Map<string, Promise<SessionSummary>>
  readonly pendingPromptActions: Set<string>
  readonly activePromptSessions: Set<string>
  readonly promptTurnReleases: Map<string, () => void>
  readonly gatedSessions: Map<string, string>
  readonly activeTurnSessions: Set<string>
  readonly turnHeldSessions: Set<string>
  readonly restartHeldSessions: Set<string>
  readonly restart: RestartCoordinator
  readonly updateSignature: { value?: string }
}

export class EventFanout {
  readonly sinks = new Set<(event: EventEnvelope) => void>()

  constructor(readonly pubsub: PubSub.PubSub<EventEnvelope>) {}

  publish(event: EventEnvelope): Effect.Effect<void> {
    const pubsub = this.pubsub
    const sinks = this.sinks
    return Effect.gen(function* () {
      yield* PubSub.publish(pubsub, event)
      yield* Effect.sync(() => {
        for (const sink of sinks) {
          sink(event)
        }
      })
    })
  }

  subscribe(sink: (event: EventEnvelope) => void): () => void {
    this.sinks.add(sink)
    return () => {
      this.sinks.delete(sink)
    }
  }
}

export const makeEventFanout: Effect.Effect<EventFanout> = Effect.map(
  PubSub.unbounded<EventEnvelope>({ replay: 256 }),
  (pubsub) => new EventFanout(pubsub)
)
