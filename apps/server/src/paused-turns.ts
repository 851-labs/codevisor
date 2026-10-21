import { Option, Schema } from "effect"

import { readJsonStateFile, removeJsonStateFile, writeJsonStateFile } from "./json-state-file.js"

export const PausedTurn = Schema.Struct({
  sessionId: Schema.String,
  turnId: Schema.optional(Schema.String),
  pausedAt: Schema.String,
  awaitsBotReply: Schema.optional(Schema.Boolean)
})
export type PausedTurn = typeof PausedTurn.Type

export interface PausedTurnStore {
  readonly read: () => ReadonlyArray<PausedTurn>
  readonly add: (turns: ReadonlyArray<PausedTurn>) => void
  readonly remove: (sessionId: string) => void
}

export const makeFilePausedTurnStore = (path: string): PausedTurnStore =>
  pausedTurnStore(
    () => decodePausedTurns(readJsonStateFile(path)),
    (turns) => {
      if (turns.length === 0) {
        removeJsonStateFile(path)
        return
      }
      writeJsonStateFile(path, { turns })
    }
  )

export const makeMemoryPausedTurnStore = (): PausedTurnStore => {
  let saved: ReadonlyArray<PausedTurn> = []
  return pausedTurnStore(
    () => saved,
    (turns) => {
      saved = turns
    }
  )
}

export const observePausedTurns = (
  store: PausedTurnStore,
  onChange: () => void
): PausedTurnStore => ({
  read: store.read,
  add: (turns) => {
    store.add(turns)
    onChange()
  },
  remove: (sessionId) => {
    const wasPaused = store.read().some((turn) => turn.sessionId === sessionId)
    store.remove(sessionId)
    if (wasPaused) onChange()
  }
})

const pausedTurnStore = (
  load: () => ReadonlyArray<PausedTurn>,
  save: (turns: ReadonlyArray<PausedTurn>) => void
): PausedTurnStore => {
  const without = (sessionIds: ReadonlySet<string>): ReadonlyArray<PausedTurn> =>
    load().filter((turn) => !sessionIds.has(turn.sessionId))

  return {
    read: load,
    add: (turns) => save([...without(new Set(turns.map((turn) => turn.sessionId))), ...turns]),
    remove: (sessionId) => save(without(new Set([sessionId])))
  }
}

const PausedTurnsFile = Schema.Struct({ turns: Schema.Array(PausedTurn) })

const decodePausedTurnsFile = Schema.decodeUnknownOption(PausedTurnsFile)

const decodePausedTurns = (value: unknown): ReadonlyArray<PausedTurn> =>
  Option.match(decodePausedTurnsFile(value), { onNone: () => [], onSome: (file) => file.turns })
