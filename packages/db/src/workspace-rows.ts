export interface WorkspaceRow {
  readonly sidebar_position: string
  readonly sidebar_order_revision: number
  readonly id: string
  readonly server_id: string
  readonly project_id: string
  readonly name: string
  readonly has_custom_name: number
  readonly root_directory: string | null
  readonly is_archived: number
  readonly archived_at: string | null
  readonly created_at: string
  readonly updated_at: string | null
  readonly labels?: string | null
}

export interface WorkspacePaneRow {
  readonly id: string
  readonly workspace_id: string
  readonly provider_id: string
  readonly pane_type: string
  readonly title: string
  readonly resource_kind: string | null
  readonly resource_id: string | null
  readonly metadata: string | null
  readonly live_title: string | null
  readonly terminal_activity: "working" | "idle" | null
  readonly revision: number
  /// The shared tab order key. Inserts and the upgrade assign one; the
  /// column default of "" only covers rows written outside the service.
  readonly position: string
  readonly created_at: string
  readonly updated_at: string | null
}
