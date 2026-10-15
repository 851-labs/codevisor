import { ArchivedWorktreeState, SessionOrigin, type Project } from "@codevisor/api"
import { Schema } from "effect"

import { integer, nullable, optional, rowReader, text } from "./row-reader.js"

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

export const projectRows = rowReader<ProjectRow>({
  id: text,
  name: text,
  origin: Schema.is(SessionOrigin),
  created_at: text,
  repo_url: nullable(text),
  worktree_base_remote: nullable(text),
  worktree_base_branch: nullable(text),
  default_run_location: nullable(text)
})

export const archivedWorktreeRows = rowReader<ArchivedWorktreeRow>({
  id: text,
  project_id: text,
  server_id: text,
  original_name: text,
  branch: text,
  parent_sha: text,
  snapshot_ref: text,
  created_at: text,
  state: Schema.is(ArchivedWorktreeState)
})

export const projectLocationRows = rowReader<ProjectLocationRow>({
  id: text,
  project_id: text,
  server_id: text,
  folder_path: text,
  is_git_repository: optional(nullable(integer)),
  created_at: text
})

export const worktreeRows = rowReader<WorktreeRow>({
  id: text,
  project_id: text,
  server_id: text,
  name: text,
  branch: text,
  created_at: text
})
