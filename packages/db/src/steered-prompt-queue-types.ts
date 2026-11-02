import type { PromptQueueItem } from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"

export interface SteeredPromptQueueService {
  readonly listVisiblePromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly markPromptQueueItemSteered: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly takeSteeredPromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<PromptQueueItem | undefined, DatabaseError>
  readonly releaseSteeredPromptQueueItems: (
    sessionId: string,
    queueItemId?: string
  ) => Effect.Effect<void, DatabaseError>
}
