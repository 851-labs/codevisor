import { CheckCircle2Icon, CircleDashedIcon, CircleIcon } from "lucide-react"

import { cn } from "../../lib/cn"
import type { PlanEntryInfo } from "../../lib/session-events"

function statusIcon(status: string) {
  switch (status) {
    case "completed":
      return <CheckCircle2Icon className="size-3.5 text-[var(--herdman-status-ok)]" />
    case "in_progress":
      return <CircleDashedIcon className="text-foreground size-3.5 animate-spin" />
    default:
      return <CircleIcon className="text-muted-foreground/60 size-3.5" />
  }
}

// The agent's plan/todo checklist (PlanView.swift).
export function PlanView({ entries }: { entries: readonly PlanEntryInfo[] }) {
  return (
    <ul className="flex flex-col gap-1.5">
      {entries.map((entry, index) => (
        <li key={index} className="flex items-start gap-2 text-sm">
          <span className="mt-0.5 shrink-0">{statusIcon(entry.status)}</span>
          <span
            className={cn(
              entry.status === "completed"
                ? "text-muted-foreground line-through"
                : "text-foreground"
            )}
          >
            {entry.content}
          </span>
        </li>
      ))}
    </ul>
  )
}
