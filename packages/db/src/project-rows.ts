import type { ArchivedWorktreeState, Project } from "@codevisor/api"

export interface ProjectRow {
  readonly id: string
  readonly name: string
  readonly origin: Project["origin"]
  readonly created_at: string
  readonly repo_url: string | null
  readonly worktree_base_remote: string | null
  readonly worktree_base_branch: string | null
  readonly default_run_location: string | null
}

export interface ArchivedWorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly original_name: string
  readonly branch: string
  readonly parent_sha: string
  readonly snapshot_ref: string
  readonly created_at: string
  readonly state: ArchivedWorktreeState
}

export interface ProjectLocationRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly folder_path: string
  readonly is_git_repository?: number | null
  readonly created_at: string
}

export interface WorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly name: string
  readonly branch: string
  readonly created_at: string
}
