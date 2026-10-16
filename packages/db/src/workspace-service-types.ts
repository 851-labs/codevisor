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

export type UpsertWorkspaceRecord = UpsertWorkspaceRequest & { readonly botId?: string }

export type CreateWorkspaceWithSessionRecord = Omit<CreateWorkspaceRequest, "workspace"> & {
  readonly workspace: UpsertWorkspaceRecord
}

export type CreateWorkspaceWithSession = (
  request: CreateWorkspaceWithSessionRecord
) => Effect.Effect<CreateWorkspaceResponse, DatabaseError>
