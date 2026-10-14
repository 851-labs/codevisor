import type { SessionSkills } from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"

export interface SessionStateService {
  readonly getSessionRuntimeState: (sessionId: string) => Effect.Effect<unknown, DatabaseError>
  readonly saveSessionRuntimeState: (
    sessionId: string,
    metadata: unknown
  ) => Effect.Effect<void, DatabaseError>
  readonly getSessionSkills: (
    sessionId: string
  ) => Effect.Effect<SessionSkills | undefined, DatabaseError>
}
