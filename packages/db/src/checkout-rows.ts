import { integer, nullable, rowReader, text } from "./row-reader.js"

export interface CheckoutRow {
  readonly id: string
  readonly server_id: string
  readonly project_id: string
  readonly worktree_id: string | null
  readonly worktree_name: string | null
  readonly path: string
  readonly git_branch: string | null
  readonly git_detached_head: string | null
  readonly git_pull_request: string | null
  readonly git_known: number
  readonly created_at: string
  readonly updated_at: string | null
}

export const checkoutRows = rowReader<CheckoutRow>({
  id: text,
  server_id: text,
  project_id: text,
  worktree_id: nullable(text),
  worktree_name: nullable(text),
  path: text,
  git_branch: nullable(text),
  git_detached_head: nullable(text),
  git_pull_request: nullable(text),
  git_known: integer,
  created_at: text,
  updated_at: nullable(text)
})
