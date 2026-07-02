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
    case "pending":
    case "in_progress":
      return <Spinner className="size-3" />
    default:
      return null
  }
}

export function ToolCallRow({ call }: { call: ToolCallInfo }) {
  const Icon = kindIcon(call.kind)
  return (
    <div className="text-muted-foreground flex items-center gap-2 text-sm">
      <Icon className="size-3.5 shrink-0" />
      <span className="min-w-0 flex-1 truncate">{call.title ?? call.toolCallId}</span>
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
