import type { CreateSessionRequest } from "@codevisor/api"
import { Effect } from "effect"

import {
  captureServerEvent,
  serverAnalyticsInstalled
} from "../infra/analytics/server-analytics.js"

export interface BotOwnerQuery {
  readonly workspaceId?: string
  readonly sessionId?: string
}

export interface BotLookup {
  readonly findBotOwning: (query: BotOwnerQuery) => Effect.Effect<unknown, unknown>
}

export interface LayoutChange {
  readonly workspaceId: string
  readonly action: { readonly kind: string }
}

export const captureSubAgentCreated = async (
  db: BotLookup,
  serverId: string,
  payload: CreateSessionRequest
): Promise<void> => {
  if (!serverAnalyticsInstalled() || payload.createdByAgentId === undefined) return

  const byBot = await ownedByBot(db, { sessionId: payload.createdByAgentId })
  captureServerEvent({
    name: "sub agent created",
    properties: {
      harness_id: payload.harnessId,
      by_bot: byBot,
      other_machine: createdElsewhere(payload, serverId),
      uses_worktree: payload.worktreeName !== undefined
    }
  })
}

export const captureAgentLayoutChanged = async (
  db: BotLookup,
  layout: LayoutChange
): Promise<void> => {
  if (!serverAnalyticsInstalled()) return

  const inBot = await ownedByBot(db, { workspaceId: layout.workspaceId })
  captureServerEvent({
    name: "agent layout changed",
    properties: { action: layout.action.kind, in_bot: inBot }
  })
}

const createdElsewhere = (payload: CreateSessionRequest, serverId: string): boolean =>
  payload.createdByAgentMachineId !== undefined && payload.createdByAgentMachineId !== serverId

const ownedByBot = async (db: BotLookup, query: BotOwnerQuery): Promise<boolean> => {
  try {
    return (await Effect.runPromise(db.findBotOwning(query))) !== undefined
  } catch {
    return false
  }
}
