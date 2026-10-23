import type {
  CreateWorkspaceRequest,
  CreateWorkspaceResponse,
  UpsertWorkspaceRequest
} from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"

export type DeleteWorkspacePane = (
  workspaceId: string,
  paneId: string
) => Effect.Effect<void, DatabaseError>

export interface BotLink {
  readonly botId: string
  readonly botMachineId?: string
}

export interface RemoteBotLink {
  readonly parentSessionId: string
  readonly bot: Required<BotLink>
}

export type WorkspaceBotFields = Partial<BotLink> & { readonly botParentSessionId?: string }

export type UpsertWorkspaceRecord = UpsertWorkspaceRequest & WorkspaceBotFields

export type CreateWorkspaceWithSessionRecord = Omit<CreateWorkspaceRequest, "workspace"> & {
  readonly workspace: UpsertWorkspaceRecord
}

export type CreateWorkspaceWithSession = (
  request: CreateWorkspaceWithSessionRecord
) => Effect.Effect<CreateWorkspaceResponse, DatabaseError>
