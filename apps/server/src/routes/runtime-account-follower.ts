import type { EventEnvelope } from "@codevisor/api"

import { swallowError } from "../server-context.js"
import { isRecord } from "../unknown-values.js"
import { makeSerialQueue } from "./serial-queue.js"

export interface RuntimeAccountFollowerDependencies {
  readonly staleChats: (harnessId: string) => Promise<ReadonlyArray<string>>
  readonly isBusy: (chatId: string) => Promise<boolean>
  readonly restart: (chatId: string) => Promise<void>
}

export interface RuntimeAccountFollower {
  readonly handle: (event: EventEnvelope) => Promise<void>
}

export const makeRuntimeAccountFollower = (
  deps: RuntimeAccountFollowerDependencies
): RuntimeAccountFollower => {
  const waitingForIdle = new Set<string>()
  const serialized = makeSerialQueue()

  const followAccount = async (harnessId: string): Promise<void> => {
    for (const chatId of await deps.staleChats(harnessId)) await restartWhenIdle(chatId)
  }

  const restartWhenIdle = async (chatId: string): Promise<void> => {
    if (await deps.isBusy(chatId)) {
      waitingForIdle.add(chatId)
      return
    }

    waitingForIdle.delete(chatId)
    await deps.restart(chatId).catch(swallowError)
  }

  const stepFor = (event: EventEnvelope): (() => Promise<void>) | undefined => {
    if (event.kind === "harness.auth.updated") return () => followAccount(event.subjectId)
    if (!waitingForIdle.has(event.subjectId) || !endsTurn(event)) return undefined

    return () => restartWhenIdle(event.subjectId)
  }

  return {
    handle: async (event) => {
      const step = stepFor(event)
      if (step !== undefined) await serialized(step)
    }
  }
}

const endsTurn = (event: EventEnvelope): boolean => {
  if (event.kind === "session.error") return true
  return (
    event.kind === "session.updated" &&
    isRecord(event.payload) &&
    event.payload.turnState === "ended"
  )
}
