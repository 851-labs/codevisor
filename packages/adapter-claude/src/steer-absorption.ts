import { steerSettlementEvent, type SteerOutcome } from "@codevisor/agent-runtime"

import type { ClaudeSession, PendingSteer, SteerMessage } from "./session.js"

export const trackSteer = (
  session: ClaudeSession,
  steerId: string,
  message: SteerMessage
): void => {
  session.pendingSteers.push({
    id: steerId,
    message,
    startsToSkip: session.requestInFlight ? 1 : 0
  })
}

export const absorbPendingSteers = (session: ClaudeSession): boolean => {
  const absorbed = takeAbsorbedSteers(session)
  const startsTurn = !session.turnActive
  for (const steer of absorbed) settleSteer(session, steer, "absorbed", startsTurn)
  return absorbed.length > 0
}

export const dropPendingSteers = (session: ClaudeSession): void => {
  const dropped = session.pendingSteers.splice(0)
  for (const steer of dropped) settleSteer(session, steer, "dropped", false)
}

const takeAbsorbedSteers = (session: ClaudeSession): ReadonlyArray<PendingSteer> => {
  const absorbed: Array<PendingSteer> = []
  for (const steer of session.pendingSteers.splice(0)) {
    if (steer.startsToSkip > 0) {
      steer.startsToSkip -= 1
      session.pendingSteers.push(steer)
    } else {
      absorbed.push(steer)
    }
  }
  return absorbed
}

const settleSteer = (
  session: ClaudeSession,
  steer: PendingSteer,
  outcome: SteerOutcome,
  startsTurn: boolean
): void => {
  void session.emit(steerSettlementEvent(session.key, { id: steer.id, outcome, startsTurn }))
}
