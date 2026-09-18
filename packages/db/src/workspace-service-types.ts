import type { CreateWorkspaceRequest, CreateWorkspaceResponse } from "@codevisor/api"
import type { Effect } from "effect"

import type { DatabaseError } from "./errors.js"

/// Deletes a pane. A workspace may be left with no panes: clients render that
/// state with their own local New Tab page; the registry stores no placeholder.
export type DeleteWorkspacePane = (
  workspaceId: string,
  paneId: string
) => Effect.Effect<void, DatabaseError>

/// Creates a workspace around its first chat: workspace, session and chat pane
/// commit in one transaction so no client observes a chat-less workspace. An
/// existing workspace keeps its metadata. Idempotent per session id.
export type CreateWorkspaceWithSession = (
  request: CreateWorkspaceRequest
) => Effect.Effect<CreateWorkspaceResponse, DatabaseError>
