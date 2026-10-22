import { emitGoalCleared, handleGoalUpdated } from "./goals.js"
import { isRecord } from "./internal.js"
import { emitStreamedFilePatch, handleItemNotification } from "./item-notifications.js"
import { handleNotificationError } from "./notification-errors.js"
import { notificationRoute, type NotificationRoute } from "./notification-route.js"
import {
  emitAgentMessageChunk,
  emitPlanUpdate,
  emitThoughtChunk,
  emitTokenUsageUpdate,
  handleRateLimitsUpdated
} from "./notification-updates.js"
import { handleThreadNameUpdated } from "./session-title.js"
import type { CodexSession } from "./session.js"
import { refreshCodexSkills } from "./skills.js"
import { completeNotificationTurn, startNotificationTurn } from "./turn-notifications.js"

type NotificationHandler = (
  session: CodexSession,
  payload: Record<string, unknown>,
  route: NotificationRoute
) => void

export const handleNotification = (
  session: CodexSession,
  method: string,
  params: unknown
): void => {
  if (session.titleGenerator?.handleNotification(method, params)) return

  const payload = isRecord(params) ? params : {}
  const route = notificationRoute(session, method, payload)
  if (route === undefined) return

  notificationHandlers.get(method)?.(session, payload, route)
}

const notificationHandlers: ReadonlyMap<string, NotificationHandler> = new Map<
  string,
  NotificationHandler
>([
  [
    "skills/changed",
    (session) => {
      void refreshCodexSkills(session, true)
    }
  ],
  ["thread/tokenUsage/updated", emitTokenUsageUpdate],
  ["account/rateLimits/updated", handleRateLimitsUpdated],
  ["thread/name/updated", handleThreadNameUpdated],
  ["turn/started", startNotificationTurn],
  ["turn/completed", completeNotificationTurn],
  ["item/agentMessage/delta", emitAgentMessageChunk],
  ["item/reasoning/textDelta", emitThoughtChunk],
  ["item/reasoning/summaryTextDelta", emitThoughtChunk],
  [
    "item/started",
    (session, payload, route) => {
      handleItemNotification(session, payload, route, true)
    }
  ],
  [
    "item/completed",
    (session, payload, route) => {
      handleItemNotification(session, payload, route, false)
    }
  ],
  ["item/fileChange/patchUpdated", emitStreamedFilePatch],
  ["thread/goal/updated", handleGoalUpdated],
  [
    "thread/goal/cleared",
    (session) => {
      void emitGoalCleared(session)
    }
  ],
  ["turn/plan/updated", emitPlanUpdate],
  ["error", handleNotificationError]
])
