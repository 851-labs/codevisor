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

export const initialWorkspacePosition = (epoch: number, id: string): string => {
  const identity = /^[0-9a-f-]{36}$/i.test(id)
    ? "8" + id.toLowerCase().replaceAll("-", "")
    : "9" +
      Array.from(new TextEncoder().encode(id), (byte) => byte.toString(16).padStart(2, "0")).join(
        ""
      )
  return (
    (
      WORKSPACE_POSITION_EPOCH_MAX -
      Math.min(WORKSPACE_POSITION_EPOCH_MAX - 1, Math.max(0, Math.trunc(epoch)))
    )
      .toString(16)
      .padStart(12, "0") +
    identity +
    "8"
  )
}
