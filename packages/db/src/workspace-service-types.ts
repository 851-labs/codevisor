import type { CreateWorkspaceRequest, CreateWorkspaceResponse } from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"

export type DeleteWorkspacePane = (
  workspaceId: string,
  paneId: string
) => Effect.Effect<void, DatabaseError>

export type CreateWorkspaceWithSession = (
  request: CreateWorkspaceRequest
) => Effect.Effect<CreateWorkspaceResponse, DatabaseError>
