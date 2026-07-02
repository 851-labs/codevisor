import {
  CheckIcon,
  FileEditIcon,
  FileSearchIcon,
  GlobeIcon,
  SquareTerminalIcon,
  WrenchIcon,
  XIcon
} from "lucide-react"

import { Spinner } from "../../components/ui/spinner"
import type { ToolCallInfo } from "../../lib/session-events"

// ACP tool kinds → icons (ToolCallRow.swift). Rich diff/terminal previews are
// deferred; rows show icon + title + status glyph.
function kindIcon(kind: string | undefined) {
  switch (kind) {
    case "read":
    case "search":
      return FileSearchIcon
    case "edit":
    case "delete":
    case "move":
      return FileEditIcon
    case "execute":
      return SquareTerminalIcon
    case "fetch":
      return GlobeIcon
    default:
      return WrenchIcon
  }
}

function StatusGlyph({ status }: { status: string | undefined }) {
  switch (status) {
    case "completed":
      return <CheckIcon className="size-3 text-[var(--herdman-status-ok)]" />
    case "failed":
      return <XIcon className="size-3 text-[var(--herdman-status-error)]" />
    case "cancelled":
      return <XIcon className="text-muted-foreground size-3" />
    case "pending":
    case "in_progress":
      return <Spinner className="size-3" />
    default:
      return null
  }
}

// Summed +N/−N across the call's per-path diff stats; re-renders (and thus
// counts up) as streamed updates merge in.
function DiffBadge({ call }: { call: ToolCallInfo }) {
  const stats = call.diffStats
  if (stats == null || stats.length === 0) return null
  let added = 0
  let removed = 0
  for (const stat of stats) {
    added += stat.added
    removed += stat.removed
  }
  return (
    <span className="shrink-0 font-mono text-xs tabular-nums">
      <span className="text-[var(--herdman-status-ok)]">+{added}</span>{" "}
      <span className="text-[var(--herdman-status-error)]">−{removed}</span>
    </span>
  )
}

export function ToolCallRow({ call }: { call: ToolCallInfo }) {
  const Icon = kindIcon(call.kind)
  return (
    <div className="text-muted-foreground flex items-center gap-2 text-sm">
      <Icon className="size-3.5 shrink-0" />
      <span className="min-w-0 flex-1 truncate">{call.title ?? call.toolCallId}</span>
      <DiffBadge call={call} />
      <StatusGlyph status={call.status} />
    </div>
  )
}

export function ToolGroup({ calls }: { calls: readonly ToolCallInfo[] }) {
  return (
    <div className="flex flex-col gap-1.5">
      {calls.map((call) => (
        <ToolCallRow key={call.toolCallId} call={call} />
      ))}
    </div>
  )
}
