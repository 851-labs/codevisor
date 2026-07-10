import { ChevronRightIcon, TriangleAlertIcon } from "lucide-react"
import { useEffect, useRef, useState } from "react"

import { ShimmerText } from "../../components/ShimmerText"
import { cn } from "../../lib/cn"
import type { SessionSetupPhaseInfo } from "../../lib/session-setup"

export function formatSetupSeconds(seconds: number): string {
  return seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`
}

export function runningSetupTitle(activeTitle: string): string {
  return `${activeTitle}…`
}

function durationSeconds(phase: SessionSetupPhaseInfo): number | undefined {
  if (phase.endedAt == null) return undefined
  const duration = Math.round(
    (new Date(phase.endedAt).getTime() - new Date(phase.startedAt).getTime()) / 1000
  )
  return Math.max(0, duration)
}

function useElapsedSeconds(startedAt: string, active: boolean): number {
  const [elapsed, setElapsed] = useState(0)
  useEffect(() => {
    if (!active) return
    const started = new Date(startedAt).getTime()
    const tick = () => setElapsed(Math.max(0, Math.floor((Date.now() - started) / 1000)))
    tick()
    const timer = setInterval(tick, 1000)
    return () => clearInterval(timer)
  }, [active, startedAt])
  return elapsed
}

export function SessionSetupView({ phases }: { phases: readonly SessionSetupPhaseInfo[] }) {
  if (phases.length === 0) return null
  return (
    <div className="flex w-full flex-col gap-3.5">
      {phases.map((phase) => (
        <SessionSetupPhaseView key={phase.id} phase={phase} />
      ))}
    </div>
  )
}

function SessionSetupPhaseView({ phase }: { phase: SessionSetupPhaseInfo }) {
  const [isExpanded, setIsExpanded] = useState(phase.failureMessage != null)
  const [hasAutoExpandedFailure, setHasAutoExpandedFailure] = useState(phase.failureMessage != null)
  const logRef = useRef<HTMLDivElement>(null)
  const elapsed = useElapsedSeconds(phase.startedAt, phase.outcome === "running")
  const hasDetail = phase.logs.length > 0 || phase.failureMessage != null

  useEffect(() => {
    if (phase.outcome === "failed" && !hasAutoExpandedFailure) {
      setHasAutoExpandedFailure(true)
      setIsExpanded(true)
      return
    }
    if (phase.outcome === "succeeded") setIsExpanded(false)
  }, [hasAutoExpandedFailure, phase.outcome])

  useEffect(() => {
    const container = logRef.current
    if (container == null) return
    container.scrollTop = container.scrollHeight
  }, [phase.logs.length, isExpanded])

  return (
    <section className="flex min-w-0 flex-col gap-3 overflow-hidden">
      {hasDetail ? (
        <button
          type="button"
          onClick={() => setIsExpanded((expanded) => !expanded)}
          className="text-muted-foreground flex cursor-default items-center gap-1.5 text-left text-sm outline-none"
        >
          <SetupLabel phase={phase} elapsed={elapsed} />
          <ChevronRightIcon
            className={cn(
              "text-muted-foreground/60 size-3 transition-transform",
              isExpanded && "rotate-90"
            )}
            strokeWidth={2.4}
          />
        </button>
      ) : (
        <div className="text-muted-foreground flex items-center gap-1.5 text-sm">
          <SetupLabel phase={phase} elapsed={elapsed} />
        </div>
      )}

      {isExpanded && hasDetail && (
        <div className="flex flex-col gap-2 border-t border-[var(--herdman-separator)] pt-2">
          {phase.failureMessage != null && (
            <div className="herdman-selectable flex items-start gap-1.5 text-sm text-[var(--herdman-status-error)]">
              <TriangleAlertIcon className="mt-0.5 size-4 shrink-0" />
              <span className="min-w-0 break-words">{phase.failureMessage}</span>
            </div>
          )}
          {phase.logs.length > 0 && (
            <div
              ref={logRef}
              className="herdman-scrollbar herdman-selectable max-h-[200px] overflow-y-auto rounded-lg bg-[var(--herdman-card-quiet-bg)] p-2.5 font-mono text-xs"
            >
              {phase.logs.map((line) => (
                <div
                  key={line.id}
                  className={cn(
                    "min-w-0 break-words whitespace-pre-wrap",
                    line.stream === "stderr" ? "text-muted-foreground" : "text-muted-foreground/75"
                  )}
                >
                  {line.text}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </section>
  )
}

function SetupLabel({ phase, elapsed }: { phase: SessionSetupPhaseInfo; elapsed: number }) {
  switch (phase.outcome) {
    case "running":
      return (
        <>
          <ShimmerText>{runningSetupTitle(phase.activeTitle)}</ShimmerText>
          <span className="text-muted-foreground/70 font-mono text-xs">
            {formatSetupSeconds(elapsed)}
          </span>
        </>
      )
    case "succeeded": {
      const duration = durationSeconds(phase)
      return (
        <span>
          {phase.completedTitle}{" "}
          {duration == null || duration < 1 ? "in a moment" : `in ${formatSetupSeconds(duration)}`}
        </span>
      )
    }
    case "failed":
      return (
        <span className="flex items-center gap-1 text-[var(--herdman-status-warn)]">
          <TriangleAlertIcon className="size-3.5" />
          {phase.failedTitle}
        </span>
      )
  }
}
