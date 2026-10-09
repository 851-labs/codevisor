import { Schema } from "effect"

/// Where an agent-created chat lives relative to its parent chat's
/// workspace: `shared` joins it as another tab, `owned` makes a workspace
/// the parent's owns (nested under it in the sidebar), and `independent` makes
/// a top-level workspace. Overrides `workspaceId`/`parentWorkspaceId` when
/// the parent chat has a workspace.
export const WorkspacePlacement = Schema.Literals(["shared", "owned", "independent"])
export type WorkspacePlacement = typeof WorkspacePlacement.Type
