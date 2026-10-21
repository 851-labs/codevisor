import { createHash } from "node:crypto"

import {
  OAuthRefreshRejected,
  OAuthRefreshUnavailable,
  SharedCredentialError,
  type SharedCredentialReference,
  type SharedTokenBundle
} from "./shared-credential-types.js"

export const refreshSucceededLine = (
  reference: SharedCredentialReference,
  presented: SharedTokenBundle,
  next: SharedTokenBundle
): string =>
  `${refreshPrefix(reference, presented)}: rotated, next=${fingerprint(next.refreshToken)}`

export const refreshFailedLine = (
  reference: SharedCredentialReference,
  presented: SharedTokenBundle,
  cause: unknown
): string => `${refreshPrefix(reference, presented)}: ${failureOutcome(cause)}`

export const fingerprint = (value: string | undefined): string => {
  if (value === undefined) return "none"
  return createHash("sha256").update(value).digest("hex").slice(0, fingerprintLength)
}

const fingerprintLength = 8

const refreshPrefix = (reference: SharedCredentialReference, presented: SharedTokenBundle) =>
  `Shared credential refresh ${presented.harnessId} login=${fingerprint(reference.id)} presented=${fingerprint(presented.refreshToken)}`

const failureOutcome = (cause: unknown): string => {
  if (cause instanceof OAuthRefreshRejected)
    return `rejected HTTP ${cause.status} ${cause.code ?? "without an error code"}`
  if (cause instanceof OAuthRefreshUnavailable) return `unavailable (${cause.detail})`
  if (cause instanceof SharedCredentialError) return `failed (${cause.reason})`
  return `network failure (${cause instanceof Error ? cause.name : "unknown"})`
}
