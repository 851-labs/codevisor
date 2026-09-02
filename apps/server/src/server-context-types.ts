import type { CredentialSource } from "@codevisor/harness-manager"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type { EventEnvelope, ServerKind, SessionSummary, UpdateInfo } from "@codevisor/api"
import type { AttachmentStore, CodevisorDatabaseService } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { IncomingMessage, ServerResponse } from "node:http"
import type { Socket } from "node:net"
import { Context, Effect, Layer, PubSub, Schema } from "effect"
import type { ServerUpdateChannel } from "@codevisor/updater"
import type { SessionActivityController } from "./infra/active-work-sleep-inhibitor.js"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import type { HarnessLifecycleManager } from "@codevisor/harness-manager"
import type { CustomHarnessStore } from "@codevisor/harness-manager"
import type { McpManager } from "@codevisor/mcp"
import type { NativeMcpManager } from "@codevisor/mcp"
import type { SkillsManager } from "@codevisor/skills"
import type { PluginRegistryClient, PluginsManager } from "@codevisor/plugins"

/// The server's service/config contracts, the Effect service tag, and the
/// event fanout every route publishes through.

export class ServerError extends Schema.TaggedErrorClass<ServerError>()("ServerError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface CodevisorServerAuthConfig {
  readonly requireBearerToken: boolean
  readonly allowLocalhostWithoutAuth: boolean
}

/// Lets the host process implement self-updating: `check` refreshes and
/// returns the update state (`force` bypasses any host-side cache, `channel`
/// selects the release feed), `apply` installs the newer release and
/// restarts the server process. Wired up in main.ts; absent in tests and
/// embedded runs.
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
  /// Whether cloud clients may discover and open the direct LAN channel.
  /// Disable this for relay-only fixtures; ordinary servers keep it enabled.
  readonly directPathEnabled: boolean
  readonly worktreeNameStyle: "production" | "development"
  readonly auth: CodevisorServerAuthConfig
  /// Invoked after `POST /v1/shutdown` is acknowledged so the host process can
  /// exit (used by the macOS app to swap in an updated server runtime).
  readonly onShutdownRequested?: (() => void) | undefined
  readonly updater?: CodevisorServerUpdater | undefined
  /// Host power policy for active locally hosted turns. The production macOS
  /// server supplies a scoped idle-sleep assertion; other platforms/tests
  /// omit it.
  readonly sessionActivity?: SessionActivityController | undefined
  /// This machine's Codevisor Cloud device id (from `codevisor auth login`),
  /// advertised via /v1/info so clients can match this machine to its cloud
  /// presence entry instead of guessing by display name. When `cloud` is
  /// present its live device id wins over this boot-time snapshot.
  readonly cloudDeviceId?: string | undefined
  /// Live control over this machine's cloud registration (present when the
  /// hosting process can start/stop the cloud bridge at runtime). Lets the
  /// desktop app register this machine on the signed-in account via
  /// /v1/cloud/connect instead of requiring a separate `codevisor auth login`.
  readonly cloud?: CloudServerControl | undefined
}

export interface CloudServerControl {
  readonly deviceId: () => string | undefined
  readonly state: () => string | undefined
  /// "app" registrations follow the desktop app's account session; "external"
  /// ones (`codevisor auth login`, dev auto-provision) outlive it.
  readonly managedBy: () => "app" | "external" | undefined
  /// Provisions this machine on the account behind sessionToken and starts
  /// the bridge; resolves to the new cloud device id.
  readonly connect: (serverUrl: string, sessionToken: string) => Promise<string>
  /// Stops the bridge and forgets the stored credential.
  readonly disconnect: () => Promise<void>
  /// Adopts one server-accepted WebSocket as a direct sealed-channel pipe
  /// (see @codevisor/cloud-client DirectChannelHost). False when no bridge
  /// is running — the caller closes the socket.
  readonly acceptDirect?: (socket: import("@codevisor/cloud-client").CloudSocket) => boolean
}

export interface CodevisorServerServices {
  readonly db: CodevisorDatabaseService
  readonly attachments: AttachmentStore
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  /// Full user shell environment for Git operations that can invoke checkout
  /// hooks and filters. GUI-launched macOS servers otherwise inherit a PATH
  /// that omits Homebrew tools such as git-lfs.
  readonly resolveGitEnvironment?: () => Promise<NodeJS.ProcessEnv>
  readonly auth?: HarnessAuthManager
  readonly credentialFerry?: ReadonlyArray<CredentialSource>
  readonly mcp?: McpManager
  /// User-defined custom ACP harness persistence + handshake probe. Absent on
  /// hosts that don't support it (embedded runtimes, tests) — routes 501.
  readonly customHarnesses?: CustomHarnessStore
  /// Harness install/update lifecycle (update detection, later install/
  /// update execution). Absent on hosts that don't support it.
  readonly lifecycle?: HarnessLifecycleManager
  /// Discovery over MCP servers registered directly in harness config files.
  /// Absent on hosts that don't support it — routes 501.
  readonly nativeMcp?: NativeMcpManager
  /// Skills discovery over the canonical store and harness skills dirs.
  /// Absent on hosts that don't support it — routes 501.
  readonly skills?: SkillsManager
  /// Plugin runtime: supervised local plugin servers whose panes are proxied
  /// under /v1/plugins/:id/app/*. Absent on hosts that don't support it —
  /// routes 501.
  readonly plugins?: PluginsManager
  /// Read-through cache over the hosted plugin registry index, so clients
  /// browse plugins through their machine instead of the cloud. Absent on
  /// hosts that don't support it — the registry route 501s.
  readonly pluginRegistry?: PluginRegistryClient
  /// Content-addressed archive store for the config plane's big payloads
  /// (skill directories, keyed by tree hash). Absent on hosts without a
  /// data directory — the blob routes 501.
  readonly syncBlobs?: import("@codevisor/sync").BlobStore
}

export interface RunningCodevisorServer {
  readonly url: string
  readonly host: string
  readonly port: number
  readonly close: Effect.Effect<void, ServerError>
}

export interface CodevisorServerApp {
  readonly handleRequest: (request: IncomingMessage, response: ServerResponse) => void
  readonly handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer) => void
  readonly close: Effect.Effect<void, ServerError>
}

export interface RouteState {
  readonly pendingSessionCreates: Map<string, Promise<SessionSummary>>
  readonly pendingPromptActions: Set<string>
  readonly activePromptSessions: Set<string>
  /// Sessions whose prompt dispatch is held by a harness update gate, keyed
  /// to the harness they wait on. Cleared (and re-drained) on gate release.
  readonly gatedSessions: Map<string, string>
  /// Sessions with a live turn, tracked from `turnState` lifecycle events on
  /// the fanout. Unlike `activePromptSessions` (turns this process
  /// dispatched), this also sees turns the harness starts on its own — a
  /// task-notification follow-up after a background task finishes. Prompt
  /// dispatch holds while a session is in here.
  readonly activeTurnSessions: Set<string>
  /// Sessions whose queue drain was held because a turn was active.
  /// Re-drained when that turn's terminal event arrives.
  readonly turnHeldSessions: Set<string>
  /// The last published release-state fingerprint, so repeated update
  /// checks with an unchanged outcome emit no update.changed event.
  readonly updateSignature: { value?: string }
}

export class CodevisorServer extends Context.Service<CodevisorServer, CodevisorServerServices>()(
  "@codevisor/server/CodevisorServer"
) {
  static readonly layer = (services: CodevisorServerServices): Layer.Layer<CodevisorServer> =>
    Layer.succeed(CodevisorServer, CodevisorServer.of(services))
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

/// Attachment temp files older than this are swept at server start; agents
/// may read a materialized path late in a turn, so nothing is deleted while
/// a session could still reference it.
