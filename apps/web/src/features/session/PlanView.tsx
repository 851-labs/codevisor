import {
  CheckCircle2Icon,
  ChevronDownIcon,
  CircleIcon,
  ClipboardListIcon,
  ListTodoIcon
} from "lucide-react"

import { cn } from "../../lib/cn"
import type { PlanEntryInfo } from "../../lib/session-events"
import { StreamingMarkdown } from "../../components/markdown/StreamingMarkdown"

function statusIcon(status: string) {
  switch (status) {
    case "completed":
      return (
        <CheckCircle2Icon className="text-background size-3.5 fill-[var(--herdman-status-ok)]" />
      )
    case "in_progress":
      return (
        <span
          aria-hidden="true"
          className="text-foreground relative inline-block size-3.5 overflow-hidden rounded-full border border-current"
        >
          <span className="absolute inset-y-0 left-0 w-1/2 bg-current" />
        </span>
      )
    default:
      return <CircleIcon className="text-muted-foreground/60 size-3.5" />
  }
}

export function todoEntryTextClassName(status: string): string {
  return cn(
    status === "in_progress" && "text-foreground font-medium",
    status === "completed" && "text-muted-foreground line-through",
    status !== "completed" && status !== "in_progress" && "text-muted-foreground"
  )
}

// Inline fallback for old callers; the current session UI renders these
// session-level snapshots through TodoPanelView above the composer.
export function PlanView({ entries }: { entries: readonly PlanEntryInfo[] }) {
  return (
    <ul className="flex flex-col gap-1.5">
      {entries.map((entry, index) => (
        <li key={index} className="flex items-start gap-2 text-sm">
          <span className="mt-0.5 shrink-0">{statusIcon(entry.status)}</span>
          <span className={todoEntryTextClassName(entry.status)}>{entry.content}</span>
        </li>
      ))}
    </ul>
  )
}

// The session's latest todo checklist, pinned above the composer
// (TodoPanelView.swift).
export function TodoPanelView({
  entries,
  isExpanded,
  onToggle
}: {
  entries: readonly PlanEntryInfo[]
  isExpanded: boolean
  onToggle: () => void
}) {
  const completedCount = entries.filter((entry) => entry.status === "completed").length
  const currentStep =
    entries.find((entry) => entry.status === "in_progress") ??
    entries.find((entry) => entry.status === "pending")
  const showsCollapsedCurrentStep = !isExpanded && currentStep != null

  return (
    <section className="flex flex-col gap-1.5 rounded-lg border border-[var(--herdman-separator)] bg-[var(--herdman-card-bg)] p-2.5">
      <button
        type="button"
        aria-label={`Todos, ${completedCount} of ${entries.length} done`}
        onClick={onToggle}
        className="flex cursor-default items-center gap-1.5 text-left outline-none"
      >
        <ListTodoIcon className="text-muted-foreground size-3.5" />
        <span className="text-xs font-semibold">Todos</span>
        <span className="text-muted-foreground/80 text-[11px] tabular-nums">
          {completedCount}/{entries.length}
        </span>
        {showsCollapsedCurrentStep && (
          <span className="text-muted-foreground min-w-0 flex-1 truncate text-xs">
            {currentStep.content}
          </span>
        )}
        {!showsCollapsedCurrentStep && <span className="flex-1" />}
        <ChevronDownIcon
          className={cn(
            "text-muted-foreground/70 size-3 transition-transform",
            !isExpanded && "-rotate-90"
          )}
          strokeWidth={2.5}
        />
      </button>
      {isExpanded && (
        <ul className="flex flex-col gap-1">
          {entries.map((entry, index) => (
            <li key={index} className="flex items-start gap-1.5 text-sm">
              <span className="mt-0.5 shrink-0">{statusIcon(entry.status)}</span>
              <span className={todoEntryTextClassName(entry.status)}>{entry.content}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

// Free-form plan document proposed by the agent before implementation
// (PlanDocumentView.swift), separate from the pinned todo checklist.
export function ProposedPlanView({ markdown }: { markdown: string }) {
  return (
    <section
      aria-label="Proposed plan"
      className="flex flex-col gap-2 rounded-lg border border-[var(--herdman-separator)] bg-[var(--herdman-card-bg)] p-3"
    >
      <div className="text-muted-foreground flex items-center gap-1.5 text-sm font-semibold">
        <ClipboardListIcon className="size-3.5" />
        <span>Proposed Plan</span>
      </div>
      <StreamingMarkdown markdown={markdown} />
    </section>
  )
}
