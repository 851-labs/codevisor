import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "../../server-context.js"
import type { PluginEvents } from "../events/plugin-events.js"
import { authOf, makePluginDirectory, type PluginDirectory } from "./plugin-directory.js"
import { makePluginSetupBroker, type PluginSetupBroker, type WaitingSetup } from "./plugin-setup.js"

export interface PluginDiscovery {
  readonly directory: PluginDirectory
  readonly setup: PluginSetupBroker
  readonly close: () => void
}

export const startPluginDiscovery = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  events: PluginEvents | undefined,
  machine: { readonly id: string; readonly name: string }
): PluginDiscovery | undefined => {
  const { mcp, pluginCatalog, pluginPlatform } = services
  if (mcp === undefined || pluginCatalog === undefined) return undefined
  const directory = makePluginDirectory({
    catalog: pluginCatalog,
    servers: () => mcp.list(),
    accountLabels: async (serverId) =>
      ((await pluginPlatform?.accounts.choices(serverId).catch(() => [])) ?? []).map(
        (choice) => choice.label
      ),
    tools: async (serverId) => mcp.tools(serverId),
    eventTypes: async () => (await events?.types()) ?? []
  })
  const setup = makePluginSetupBroker({
    directory,
    machine,
    emit: async (sessionId, payload) => {
      await appendAndPublish(services.db, fanout, "session.output", sessionId, payload)
    },
    wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms).unref()),
    prepare: async (target) => {
      if (target.server === undefined || authOf(target) !== "mcpOAuth") return
      await mcp.beginOAuth(target.server.id)
    },
    isAsking: async (sessionId, questionId) =>
      (await run(services.db.getTranscriptPage(sessionId, undefined, 1))).pendingQuestion
        ?.questionId === questionId,
    waiting: () => waitingSetups(services)
  })
  void setup.adoptWaiting().catch(swallowError)
  const refresh = () => {
    void setup.refresh().catch(swallowError)
  }
  const unsubscribers = [
    mcp.subscribeServersChanged(refresh),
    pluginPlatform?.onAccountsChanged(refresh)
  ]
  return {
    directory,
    setup,
    close: () => {
      for (const unsubscribe of unsubscribers) unsubscribe?.()
    }
  }
}

const waitingSetups = async (
  services: CodevisorServerServices
): Promise<ReadonlyArray<WaitingSetup>> => {
  const asking = (await run(services.db.listSessions)).filter(
    (session) => session.actionRequiredKind === "question"
  )
  const waiting: Array<WaitingSetup> = []
  for (const session of asking) {
    const pending = await run(services.db.getSessionPendingQuestion(session.id))
    if (pending === undefined) continue
    const { questionId, questions } = pending
    waiting.push(...questions.map((question) => ({ sessionId: session.id, questionId, question })))
  }
  return waiting
}
