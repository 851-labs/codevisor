import { randomUUID } from "node:crypto"

import type { PluginSetupPayload, PluginSetupRequest, PluginSetupState } from "@codevisor/api"

import type { PendingSessionEvent } from "../../routes/session-event-outbox.js"
import { failureMessage, HttpFailure } from "../../server-context.js"
import {
  authOf,
  capabilitiesOf,
  type PluginDirectory,
  type PluginDirectoryItem,
  type PluginTarget
} from "./plugin-directory.js"
import { pluginSetupFinishedEvent } from "./plugin-setup-messages.js"

export type PluginSetupOutcomeKind = "ready" | "requested" | "disabled"

export type PluginSetupNeed = "install" | "connect"

export interface PluginSetupOutcome {
  readonly outcome: PluginSetupOutcomeKind
  readonly plugin: string
  readonly name: string
  readonly accounts: ReadonlyArray<string>
  readonly needs?: PluginSetupNeed
  readonly next: string
}

export interface PluginSetupInput {
  readonly sessionId: string
  readonly plugin: string
  readonly reason: string
}

export interface PluginSetupBroker {
  readonly request: (input: PluginSetupInput) => Promise<PluginSetupOutcome>
  readonly refresh: () => Promise<void>
  readonly adoptPending: () => Promise<void>
}

export interface ShownSetup {
  readonly setupId: string
  readonly sessionId: string
  readonly request: PluginSetupRequest
}

export interface PluginSetupDeps {
  readonly directory: PluginDirectory
  readonly emit: (sessionId: string, payload: PluginSetupPayload) => Promise<void>
  readonly notify: (sessionId: string, event: PendingSessionEvent) => Promise<void>
  readonly machine: { readonly id: string; readonly name: string }
  readonly prepare: (target: PluginTarget) => Promise<void>
  readonly pending: () => Promise<ReadonlyArray<ShownSetup>>
}

export const makePluginSetupBroker = (deps: PluginSetupDeps): PluginSetupBroker => {
  const pending = new Map<string, ShownSetup>()

  const alreadyShown = (input: PluginSetupInput, target: PluginTarget): boolean =>
    [...pending.values()].some(
      (setup) => setup.sessionId === input.sessionId && namesSamePlugin(setup, target)
    )

  const show = async (input: PluginSetupInput, target: PluginTarget): Promise<void> => {
    await deps.prepare(target).catch((cause: unknown) => {
      throw new HttpFailure(
        409,
        `${nameOf(target)} can't start sign-in on ${deps.machine.name}: ${failureMessage(cause)}. No setup card was shown.`
      )
    })
    const setup = newSetup(input, target, deps.machine)
    pending.set(setup.setupId, setup)
    await deps.emit(setup.sessionId, setupPayload(setup, "pending"))
  }

  const finish = async (setup: ShownSetup, item: PluginDirectoryItem): Promise<void> => {
    await deps
      .emit(setup.sessionId, setupPayload(finishedWith(setup, item), "connected"))
      .catch(() => undefined)
    await deps
      .notify(setup.sessionId, pluginSetupFinishedEvent(item, deps.machine))
      .catch(() => undefined)
  }

  const refresh = async (): Promise<void> => {
    for (const setup of pending.values()) {
      const target = await deps.directory.find(setup.request.plugin)
      if (target === undefined) continue

      const item = await deps.directory.item(target)
      if (!item.ready || !pending.delete(setup.setupId)) continue

      await finish(setup, item)
    }
  }

  return {
    request: async (input) => {
      const target = await requireTarget(deps, input.plugin)
      const item = await deps.directory.item(target)
      if (item.ready) return outcome("ready", item)
      if (item.installed && !item.enabled) return outcome("disabled", item)

      if (!alreadyShown(input, target)) await show(input, target)
      return outcome("requested", item)
    },
    refresh,
    adoptPending: async () => {
      for (const setup of await deps.pending()) pending.set(setup.setupId, setup)
      await refresh()
    }
  }
}

const outcome = (kind: PluginSetupOutcomeKind, item: PluginDirectoryItem): PluginSetupOutcome => ({
  outcome: kind,
  plugin: item.plugin,
  name: item.name,
  accounts: item.accounts,
  ...(kind === "requested" ? { needs: needOf(item) } : {}),
  next: nextStep(kind, item)
})

const needOf = (item: PluginDirectoryItem): PluginSetupNeed =>
  item.installed ? "connect" : "install"

const nextStep = (kind: PluginSetupOutcomeKind, item: PluginDirectoryItem): string => {
  if (kind === "ready") return `${item.name} is ready to use. No card was shown.`
  if (kind === "disabled") {
    return `${item.name} is installed but turned off, so no card was shown. Ask the user to turn it on in Settings › Plugins.`
  }
  return `A card to ${cardAction(item)} is in the chat and stays there. Tell the user in one sentence what it's for, then end your turn. A hidden <codevisor-event type="plugin.setup_finished"> arrives when ${item.name} is ready, so don't wait, poll, or call this again.`
}

const cardAction = (item: PluginDirectoryItem): string =>
  item.installed ? `connect ${item.name}` : `install ${item.name}`

const namesSamePlugin = (setup: ShownSetup, target: PluginTarget): boolean => {
  const shown = setup.request
  if (shown.plugin === target.plugin) return true
  return shown.catalogId !== undefined && shown.catalogId === target.entry?.id
}

const newSetup = (
  input: PluginSetupInput,
  target: PluginTarget,
  machine: { readonly id: string; readonly name: string }
): ShownSetup => ({
  setupId: `plugin-setup:${randomUUID()}`,
  sessionId: input.sessionId,
  request: setupRequest(input, target, machine)
})

const setupRequest = (
  input: PluginSetupInput,
  target: PluginTarget,
  machine: { readonly id: string; readonly name: string }
): PluginSetupRequest => ({
  plugin: target.plugin,
  ...(target.entry === undefined
    ? {}
    : {
        catalogId: target.entry.id,
        publisher: target.entry.publisher,
        description: target.entry.description
      }),
  ...(target.server === undefined ? {} : { serverId: target.server.id }),
  name: nameOf(target),
  reason: input.reason,
  auth: authOf(target),
  capabilities: capabilitiesOf(target),
  machine
})

const finishedWith = (setup: ShownSetup, item: PluginDirectoryItem): ShownSetup => ({
  ...setup,
  request: { ...setup.request, auth: item.auth }
})

const setupPayload = (setup: ShownSetup, state: PluginSetupState): PluginSetupPayload => ({
  sessionUpdate: "plugin_setup",
  setupId: setup.setupId,
  state,
  request: setup.request
})

const nameOf = (target: PluginTarget): string => target.server?.name ?? target.entry!.name

const requireTarget = async (deps: PluginSetupDeps, plugin: string): Promise<PluginTarget> => {
  const target = await deps.directory.find(plugin).catch((cause: unknown) => {
    throw new HttpFailure(
      503,
      `Couldn't read the plugins on ${deps.machine.name}: ${failureMessage(cause)}. No setup card was shown.`
    )
  })
  if (target !== undefined) return target
  throw new HttpFailure(404, `No plugin named "${plugin}". Search with plugins.search.`)
}
