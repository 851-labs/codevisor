import type { ConversationItem } from "@herdman/api"
import { ChevronRightIcon } from "lucide-react"
import { useEffect, useRef, useState } from "react"

import { ShimmerText } from "../../components/ShimmerText"
import { StreamingMarkdown } from "../../components/markdown/StreamingMarkdown"
import { cn } from "../../lib/cn"
import type { TurnMeta } from "../../lib/queries"
import { PlanView } from "./PlanView"
import { ToolGroup } from "./ToolGroup"

function formatSeconds(seconds: number): string {
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

// Live-incrementing elapsed seconds since `startedAt` while `active`.
function useElapsedSeconds(startedAt: string | undefined, active: boolean): number {
  const [elapsed, setElapsed] = useState(0)
  useEffect(() => {
    if (!active || startedAt == null) return
    const started = new Date(startedAt).getTime()
    const tick = () => setElapsed(Math.max(0, Math.floor((Date.now() - started) / 1000)))
    tick()
    const timer = setInterval(tick, 1000)
    return () => clearInterval(timer)
  }, [startedAt, active])
  return elapsed
}

// Renders one assistant turn: thought text and tool calls collapse into a
// "Worked for…" disclosure, the plan and final answer render below, and a
// shimmering "Thinking…" shows while the agent works with nothing visible yet
// (AssistantTurnView.swift).
export function AssistantTurn({ item, meta }: { item: ConversationItem; meta?: TurnMeta }) {
  const isGenerating = item.isGenerating
  const [isExpanded, setIsExpanded] = useState(isGenerating)
  const hasAutoCollapsed = useRef(false)
  const finishedAt = useRef<number | undefined>(undefined)

  const elapsed = useElapsedSeconds(meta?.startedAt ?? item.createdAt, isGenerating)
  const hasWorkedContent = meta != null && (meta.thoughts !== "" || meta.toolCalls.length > 0)
  const showsWorkedSection = isGenerating || hasWorkedContent
  const isThinking = isGenerating && item.text === ""

  // Expanded while running; one-time auto-collapse when the turn finishes.
  useEffect(() => {
    if (isGenerating) {
      setIsExpanded(true)
      return
    }
    if (finishedAt.current == null) finishedAt.current = Date.now()
    if (!hasAutoCollapsed.current) {
      hasAutoCollapsed.current = true
      setIsExpanded(false)
    }
  }, [isGenerating])

  const workedTitle = () => {
    if (isGenerating) return `Working for ${formatSeconds(elapsed)}`
    const started = meta?.startedAt != null ? new Date(meta.startedAt).getTime() : undefined
    const duration =
      started != null && finishedAt.current != null
        ? Math.round((finishedAt.current - started) / 1000)
        : undefined
    if (duration == null || duration < 1) return "Worked for a moment"
    return `Worked for ${formatSeconds(duration)}`
  }

  return (
    <div className="flex min-w-0 flex-col gap-3.5">
      {showsWorkedSection && (
        <div className="flex flex-col gap-3">
          <button
            type="button"
            disabled={isGenerating}
            onClick={() => setIsExpanded((expanded) => !expanded)}
            className="text-muted-foreground group flex cursor-default items-center gap-1.5 text-sm outline-none"
          >
            {workedTitle()}
            {!isGenerating && hasWorkedContent && (
              <ChevronRightIcon
                className={cn(
                  "text-muted-foreground/60 size-3 transition-transform",
                  isExpanded && "rotate-90"
                )}
              />
            )}
          </button>
          {isExpanded && hasWorkedContent && meta != null && (
            <div className="border-border flex flex-col gap-3 border-t pt-3">
              {meta.thoughts !== "" && (
                <StreamingMarkdown markdown={meta.thoughts} className="text-muted-foreground" />
              )}
              {meta.toolCalls.length > 0 && <ToolGroup calls={meta.toolCalls} />}
            </div>
          )}
        </div>
      )}

      {meta?.plan != null && meta.plan.length > 0 && <PlanView entries={meta.plan} />}

      {isThinking && <ShimmerText>Thinking…</ShimmerText>}

      {item.text !== "" && <StreamingMarkdown markdown={item.text} />}
    </div>
  )
}
