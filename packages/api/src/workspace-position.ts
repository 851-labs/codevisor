import { Schema } from "effect"

// The first 12 hex digits are an inverted logical creation time. Moves stay
// inside the observed creation range, leaving room for the next new workspace
// above every manual position. The remaining digits are a fractional key.
export const WorkspacePosition = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{12}[0-9a-f]*[1-9a-f]$/),
  Schema.isMaxLength(1024)
)
export const WORKSPACE_POSITION_EPOCH_MAX = 0xffffffffffff

export const workspacePositionEpoch = (position: string): number =>
  WORKSPACE_POSITION_EPOCH_MAX - Number.parseInt(position.slice(0, 12), 16)

const identityDigits = (id: string): string =>
  /^[0-9a-f-]{36}$/i.test(id)
    ? "8" + id.toLowerCase().replaceAll("-", "")
    : "9" +
      Array.from(new TextEncoder().encode(id), (byte) => byte.toString(16).padStart(2, "0")).join(
        ""
      )

export const initialWorkspacePosition = (epoch: number, id: string): string =>
  (
    WORKSPACE_POSITION_EPOCH_MAX -
    Math.min(WORKSPACE_POSITION_EPOCH_MAX - 1, Math.max(0, Math.trunc(epoch)))
  )
    .toString(16)
    .padStart(12, "0") +
  identityDigits(id) +
  "8"

const HEX = "0123456789abcdef"

export const isWorkspacePosition = (value: string): boolean =>
  value.length >= 13 && value.length <= 1024 && /^[0-9a-f]*[1-9a-f]$/.test(value)

/// A key strictly between two keys (either may be absent), mirroring the
/// native `WorkspacePosition.between` digit for digit so clients and servers
/// agree. Undefined when the bounds are invalid or out of order.
export const workspacePositionBetween = (
  lower: string | undefined,
  upper: string | undefined,
  id: string
): string | undefined => {
  if (lower !== undefined && !isWorkspacePosition(lower)) return undefined
  if (upper !== undefined && !isWorkspacePosition(upper)) return undefined
  if (lower !== undefined && upper !== undefined && !(lower < upper)) return undefined
  const a = lower ?? upper?.slice(0, 12) ?? "ffffffffffff"
  let b: string | undefined = upper
  let result = ""
  for (let index = 0; result.length < 980; index += 1) {
    const low = index < a.length ? HEX.indexOf(a.charAt(index)) : 0
    const high = b !== undefined && index < b.length ? HEX.indexOf(b.charAt(index)) : 16
    if (high - low > 1) {
      return result + HEX.charAt(Math.floor((low + high) / 2)) + identityDigits(id) + "8"
    }
    result += HEX.charAt(low)
    if (low < high) b = undefined
  }
  return undefined
}

/// The first tab key a workspace gets (and the migration's backfill): its
/// creation time, so pre-existing tabs start in creation order.
export const initialPanePosition = (epochMs: number, id: string): string =>
  Math.min(WORKSPACE_POSITION_EPOCH_MAX - 1, Math.max(0, Math.trunc(epochMs)))
    .toString(16)
    .padStart(12, "0") +
  identityDigits(id) +
  "8"

/// The key a newly listed tab gets: strictly after the current last tab, so
/// new tabs open at the end on every device.
export const nextPanePosition = (last: string | undefined, epochMs: number, id: string): string =>
  (last !== undefined && isWorkspacePosition(last)
    ? workspacePositionBetween(last, undefined, id)
    : undefined) ?? initialPanePosition(epochMs, id)
