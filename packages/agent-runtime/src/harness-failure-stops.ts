export type HarnessFailureStopKind = "authRequired" | "forbidden" | "harnessFailed"

export interface HarnessFailure {
  readonly message: string
  readonly status?: number | null | undefined
  readonly code?: string | undefined
}

export interface HarnessFailureStop {
  readonly stopKind: HarnessFailureStopKind
  readonly stopDetail: string
}

export const harnessFailureStop = (failure: HarnessFailure): HarnessFailureStop => ({
  stopKind: harnessFailureKind(failure),
  stopDetail: failure.message
})

export const harnessFailureKind = (failure: HarnessFailure): HarnessFailureStopKind => {
  if (isSignInFailure(failure)) return "authRequired"
  if (isAccessFailure(failure)) return "forbidden"
  return "harnessFailed"
}

const unauthorizedStatus = 401
const forbiddenStatus = 403

const signInCodes = new Set(["authentication_failed", "authentication_error", "unauthorized"])

const accessCodes = new Set([
  "oauth_org_not_allowed",
  "oauth_not_allowed_for_organization",
  "permission_error",
  "permission_denied",
  "forbidden",
  "unsupported_country_region_territory"
])

const accessText =
  /\b403\b|\bforbidden\b|\bpermission[_ ]error\b|\brequest not allowed\b|\bnot allowed to (?:use|access)\b|\bhas disabled\b.*\baccess\b|\bnot (?:available|supported) in your (?:country|region)\b|\bunsupported[_ ](?:country|region)\b|\baccess denied\b/i

const isSignInFailure = (failure: HarnessFailure): boolean =>
  failure.status === unauthorizedStatus ||
  (failure.code !== undefined && signInCodes.has(failure.code))

const isAccessFailure = (failure: HarnessFailure): boolean =>
  failure.status === forbiddenStatus ||
  (failure.code !== undefined && accessCodes.has(failure.code)) ||
  accessText.test(failure.message)
