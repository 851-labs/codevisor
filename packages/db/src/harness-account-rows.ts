import type { HarnessAccount, HarnessAuthState } from "@codevisor/api"

export interface HarnessAccountRow {
  readonly id: string
  readonly harness_id: string
  readonly profile_kind: HarnessAccount["profileKind"]
  readonly profile_key: string | null
  readonly label: string
  readonly email: string | null
  readonly organization_id: string | null
  readonly auth_method: string | null
  readonly auth_state: HarnessAuthState
  readonly can_login: number
  readonly can_logout: number
  readonly last_checked_at: string | null
  readonly detail: string | null
  readonly created_at: string
  readonly updated_at: string
  readonly removed_at: string | null
  readonly is_active: number
}

export interface HarnessAccountRecord extends HarnessAccount {
  readonly profileKey?: string
  readonly createdAt: string
  readonly updatedAt: string
}

export interface SaveHarnessAccountRequest {
  readonly id?: string
  readonly harnessId: string
  readonly profileKind: HarnessAccount["profileKind"]
  readonly profileKey?: string
  readonly label: string
  readonly email?: string
  readonly organizationId?: string
  readonly authMethod?: string
  readonly authState: HarnessAuthState
  readonly canLogin: boolean
  readonly canLogout: boolean
  readonly lastCheckedAt?: string
  readonly detail?: string
}

export interface UpdateHarnessAccountAuthRequest {
  readonly label?: string
  readonly email?: string | null
  readonly organizationId?: string | null
  readonly authMethod?: string | null
  readonly authState: HarnessAuthState
  readonly canLogin?: boolean
  readonly canLogout?: boolean
  readonly lastCheckedAt?: string
  readonly detail?: string | null
}
