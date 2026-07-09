import type { ConversationItem } from "@herdman/api"
import { ChevronRightIcon, CircleSlashIcon, CircleXIcon, WandSparklesIcon } from "lucide-react"
import { useEffect, useMemo, useRef, useState } from "react"

import { ShimmerText } from "../../components/ShimmerText"
import { StreamingMarkdown } from "../../components/markdown/StreamingMarkdown"
import { cn } from "../../lib/cn"
import type { TranscriptEntryInfo, TurnMeta } from "../../lib/queries"
import type { ToolCallInfo } from "../../lib/session-events"
import { MessageCopyButton } from "./MessageCopyButton"
import { ProposedPlanView } from "./PlanView"
import { ToolCallRow, ToolGroup } from "./ToolGroup"

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
type WorkedItem =
  | { type: "text"; id: string; markdown: string }
  | { type: "toolGroup"; id: string; calls: ToolCallInfo[] }
  | { type: "subagent"; id: string; call: ToolCallInfo }

export type TranscriptDisclosureValues = Record<string, boolean>

export function turnDisclosureKey(turnId: string): string {
  return `turn:${turnId}`
}

export function turnImplementationDisclosureKey(turnId: string): string {
  return `turnImplementation:${turnId}`
}

export function subagentDisclosureKey(toolCallId: string): string {
  return `subagent:${toolCallId}`
}

function finalTextIndex(meta: TurnMeta | undefined): number | undefined {
  if (meta == null) return undefined
  for (let index = meta.entries.length - 1; index >= 0; index -= 1) {
    const entry = meta.entries[index]
    if (entry?.type === "text" && meta.textPhases[entry.id] !== "commentary") return index
  }
  return undefined
}

function workedEntries(meta: TurnMeta | undefined, entries: readonly TranscriptEntryInfo[]) {
  const finalIndex = finalTextIndex(meta)
  return entries.filter((_, index) => index !== finalIndex)
}

function workedSlice(meta: TurnMeta, start: number, end: number): TranscriptEntryInfo[] {
  const finalIndex = finalTextIndex(meta)
  const entries: TranscriptEntryInfo[] = []
  for (let index = start; index < end; index += 1) {
    const entry = meta.entries[index]
    if (entry != null && index !== finalIndex) entries.push(entry)
  }
  return entries
}

function groupedItems(meta: TurnMeta, entries: readonly TranscriptEntryInfo[]): WorkedItem[] {
  const items: WorkedItem[] = []
  let group: ToolCallInfo[] = []
  const flush = () => {
    const first = group[0]
    if (first == null) return
    items.push({ type: "toolGroup", id: first.toolCallId, calls: group })
    group = []
  }

  for (const entry of entries) {
    if (entry.type === "text") {
      flush()
      items.push({ type: "text", id: entry.id, markdown: entry.markdown })
      continue
    }
    const call = entry.call
    if (call.kind === "agent" || meta.subagents[call.toolCallId] != null) {
      flush()
      items.push({ type: "subagent", id: call.toolCallId, call })
    } else {
      group.push(call)
    }
  }
  flush()
  return items
}

function isTrailingToolGroup(meta: TurnMeta, toolCallId: string): boolean {
  let index = -1
  for (let candidate = meta.entries.length - 1; candidate >= 0; candidate -= 1) {
    const entry = meta.entries[candidate]
    if (entry?.type === "tool" && entry.call.toolCallId === toolCallId) {
      index = candidate
      break
    }
  }
  if (index === -1) return false
  return !meta.entries.slice(index + 1).some((entry) => {
    return entry.type === "text" && entry.markdown.trim() !== ""
  })
}

function workedItemsBeforePlan(meta: TurnMeta | undefined): WorkedItem[] {
  if (meta == null) return []
  const boundary = meta.planBoundary
  if (boundary == null) return groupedItems(meta, workedEntries(meta, meta.entries))
  return groupedItems(meta, workedSlice(meta, 0, Math.min(boundary, meta.entries.length)))
}

function workedItemsAfterPlan(meta: TurnMeta | undefined): WorkedItem[] {
  if (meta == null || meta.planBoundary == null) return []
  const boundary = Math.min(meta.planBoundary, meta.entries.length)
  return groupedItems(meta, workedSlice(meta, boundary, meta.entries.length))
}

function finalMarkdown(item: ConversationItem, meta: TurnMeta | undefined): string {
  const index = finalTextIndex(meta)
  const entry = index == null ? undefined : meta?.entries[index]
  return entry?.type === "text" ? entry.markdown : item.text
}

function finalTextIsAsserted(meta: TurnMeta | undefined): boolean {
  const index = finalTextIndex(meta)
  const entry = index == null ? undefined : meta?.entries[index]
  return entry?.type === "text" && meta?.textPhases[entry.id] === "final"
}

function turnHasRunningSubagent(
  meta: TurnMeta | undefined,
  runningSubagentToolCallIds: readonly string[]
): boolean {
  if (meta == null || runningSubagentToolCallIds.length === 0) return false
  return Object.keys(meta.subagents).some((id) => runningSubagentToolCallIds.includes(id))
}

function isSettled(call: ToolCallInfo): boolean {
  return call.status === "completed" || call.status === "failed" || call.status === "cancelled"
}

function readVerifyExpanded(): boolean {
  if (typeof window === "undefined") return false
  const params = new URLSearchParams(window.location.search)
  return params.get("verify") === "expanded"
}

function useVerifyExpanded(): boolean {
  const [expanded, setExpanded] = useState(readVerifyExpanded)
  useEffect(() => {
    const update = () => setExpanded(readVerifyExpanded())
    window.addEventListener("popstate", update)
    window.addEventListener("hashchange", update)
    window.addEventListener("herdman-route-changed", update)
    return () => {
      window.removeEventListener("popstate", update)
      window.removeEventListener("hashchange", update)
      window.removeEventListener("herdman-route-changed", update)
    }
  }, [])
  return expanded
}

export function AssistantTurn({
  item,
  meta,
  runningSubagentToolCallIds = [],
  disclosureValues = {},
  setDisclosureValue = () => undefined
}: {
  item: ConversationItem
  meta?: TurnMeta
  runningSubagentToolCallIds?: readonly string[]
  disclosureValues?: TranscriptDisclosureValues
  setDisclosureValue?: (key: string, expanded: boolean) => void
}) {
  const isGenerating = item.isGenerating
  const hasRunningSubagent = turnHasRunningSubagent(meta, runningSubagentToolCallIds)
  const isActive = isGenerating || hasRunningSubagent
  const [isHovered, setIsHovered] = useState(false)
  const hasAutoCollapsed = useRef(false)
  const fallbackFinishedAt = useRef<number | undefined>(undefined)

  const elapsed = useElapsedSeconds(meta?.startedAt ?? item.createdAt, isActive)
  const planningItems = useMemo(() => workedItemsBeforePlan(meta), [meta])
  const implementationItems = useMemo(() => workedItemsAfterPlan(meta), [meta])
  const forceExpanded = useVerifyExpanded()
  const hasStructuredWorkedContent = planningItems.length > 0 || implementationItems.length > 0
  const hasLegacyWorkedContent = meta != null && (meta.thoughts !== "" || meta.toolCalls.length > 0)
  const showsPlanningSection =
    meta?.planBoundary != null
      ? planningItems.length > 0
      : isActive || hasStructuredWorkedContent || hasLegacyWorkedContent
  const responseText = finalMarkdown(item, meta)
  const isFinalAsserted = finalTextIsAsserted(meta)
  const isThinking =
    meta?.isThinking === true ||
    (isGenerating && responseText === "" && !hasStructuredWorkedContent)
  const headerLockedOpen = isActive && !hasAutoCollapsed.current
  const planningDisclosureKey = turnDisclosureKey(item.id)
  const implementationDisclosureKey = turnImplementationDisclosureKey(item.id)
  const settled = (!isGenerating || isFinalAsserted) && !hasRunningSubagent
  const defaultSectionExpanded = !settled
  const planningExpanded = disclosureValues[planningDisclosureKey] ?? defaultSectionExpanded
  const implementationExpanded =
    disclosureValues[implementationDisclosureKey] ?? defaultSectionExpanded

  // Expanded while working; one-time auto-collapse when a final answer is
  // asserted or when the turn finishes, matching AssistantTurnView.swift.
  useEffect(() => {
    if (forceExpanded) {
      return
    }
    if (isGenerating && isFinalAsserted) {
      if (!hasRunningSubagent && !hasAutoCollapsed.current) {
        hasAutoCollapsed.current = true
        setDisclosureValue(planningDisclosureKey, false)
        setDisclosureValue(implementationDisclosureKey, false)
      }
      return
    }
    if (isActive) {
      if (!hasAutoCollapsed.current) {
        setDisclosureValue(planningDisclosureKey, true)
        setDisclosureValue(implementationDisclosureKey, true)
      }
      return
    }
    if (fallbackFinishedAt.current == null) fallbackFinishedAt.current = Date.now()
    if (!hasAutoCollapsed.current) {
      hasAutoCollapsed.current = true
      setDisclosureValue(planningDisclosureKey, false)
      setDisclosureValue(implementationDisclosureKey, false)
    }
  }, [
    forceExpanded,
    hasRunningSubagent,
    implementationDisclosureKey,
    isActive,
    isFinalAsserted,
    isGenerating,
    planningDisclosureKey,
    setDisclosureValue
  ])

  const workedTitle = () => {
    if (isActive) return `Working for ${formatSeconds(elapsed)}`
    const started = meta?.startedAt != null ? new Date(meta.startedAt).getTime() : undefined
    const ended =
      meta?.endedAt != null ? new Date(meta.endedAt).getTime() : fallbackFinishedAt.current
    const duration =
      started != null && ended != null ? Math.round(Math.max(0, ended - started) / 1000) : undefined
    if (duration == null || duration < 1) return "Worked for a moment"
    return `Worked for ${formatSeconds(duration)}`
  }

  return (
    <div
      className="flex min-w-0 flex-col gap-3.5"
      onMouseEnter={() => setIsHovered(true)}
      onMouseLeave={() => setIsHovered(false)}
    >
      {showsPlanningSection && (
        <WorkedSection
          title={meta?.planBoundary != null ? "Planned" : workedTitle()}
          expanded={forceExpanded || planningExpanded}
          onToggle={() =>
            setDisclosureValue(
              planningDisclosureKey,
              forceExpanded
                ? true
                : !(disclosureValues[planningDisclosureKey] ?? defaultSectionExpanded)
            )
          }
          headerLockedOpen={headerLockedOpen}
          isTurnActive={isActive}
          meta={meta}
          items={planningItems}
          legacyFallback={!hasStructuredWorkedContent}
          runningSubagentToolCallIds={runningSubagentToolCallIds}
          forceExpanded={forceExpanded}
          disclosureValues={disclosureValues}
          setDisclosureValue={setDisclosureValue}
        />
      )}

      {meta?.planDocument != null && meta.planDocument !== "" && (
        <ProposedPlanView markdown={meta.planDocument} />
      )}

      {implementationItems.length > 0 && (
        <WorkedSection
          title={workedTitle()}
          expanded={forceExpanded || implementationExpanded}
          onToggle={() =>
            setDisclosureValue(
              implementationDisclosureKey,
              forceExpanded
                ? true
                : !(disclosureValues[implementationDisclosureKey] ?? defaultSectionExpanded)
            )
          }
          headerLockedOpen={headerLockedOpen}
          isTurnActive={isActive}
          meta={meta}
          items={implementationItems}
          runningSubagentToolCallIds={runningSubagentToolCallIds}
          forceExpanded={forceExpanded}
          disclosureValues={disclosureValues}
          setDisclosureValue={setDisclosureValue}
        />
      )}

      {isThinking && <ShimmerText>Thinking…</ShimmerText>}

      {responseText !== "" && (
        <>
          <StreamingMarkdown markdown={responseText} />
          {!isGenerating && (
            <div
              className={cn("transition-opacity", isHovered ? "opacity-100" : "opacity-0")}
              aria-hidden={!isHovered}
            >
              <MessageCopyButton text={responseText} label="Copy response" isRevealed={isHovered} />
            </div>
          )}
        </>
      )}
    </div>
  )
}

function WorkedSection({
  title,
  expanded,
  onToggle,
  headerLockedOpen,
  isTurnActive,
  meta,
  items,
  legacyFallback = false,
  runningSubagentToolCallIds,
  forceExpanded = false,
  disclosureValues,
  setDisclosureValue
}: {
  title: string
  expanded: boolean
  onToggle: () => void
  headerLockedOpen: boolean
  isTurnActive: boolean
  meta?: TurnMeta
  items: readonly WorkedItem[]
  legacyFallback?: boolean
  runningSubagentToolCallIds: readonly string[]
  forceExpanded?: boolean
  disclosureValues: TranscriptDisclosureValues
  setDisclosureValue: (key: string, expanded: boolean) => void
}) {
  const hasContent =
    items.length > 0 ||
    (legacyFallback && meta != null && (meta.thoughts !== "" || meta.toolCalls.length > 0))
  const headerContent = (
    <>
      {title}
      {!headerLockedOpen && hasContent && (
        <ChevronRightIcon
          className={cn(
            "text-muted-foreground/60 size-3 transition-transform",
            expanded && "rotate-90"
          )}
        />
      )}
    </>
  )

  return (
    <div className="flex flex-col gap-3">
      {headerLockedOpen ? (
        <div className="text-muted-foreground flex items-center gap-1.5 text-[15px]">
          {headerContent}
        </div>
      ) : (
        <button
          type="button"
          onClick={onToggle}
          className="text-muted-foreground group flex cursor-default items-center gap-1.5 text-[15px] outline-none"
        >
          {headerContent}
        </button>
      )}
      {expanded && hasContent && meta != null && (
        <div className="flex flex-col gap-3 border-t border-[var(--herdman-separator)] pt-3">
          {items.length > 0 ? (
            <TranscriptItems
              items={items}
              meta={meta}
              isTurnActive={isTurnActive}
              runningSubagentToolCallIds={runningSubagentToolCallIds}
              forceExpanded={forceExpanded}
              disclosureValues={disclosureValues}
              setDisclosureValue={setDisclosureValue}
            />
          ) : (
            <>
              {meta.thoughts !== "" && (
                <StreamingMarkdown markdown={meta.thoughts} className="text-muted-foreground" />
              )}
              {meta.toolCalls.length > 0 && (
                <ToolGroup
                  calls={meta.toolCalls}
                  isTurnActive={isTurnActive}
                  autoExpanded={isTurnActive}
                  forceExpanded={forceExpanded}
                  disclosureValues={disclosureValues}
                  setDisclosureValue={setDisclosureValue}
                />
              )}
            </>
          )}
        </div>
      )}
    </div>
  )
}

function TranscriptItems({
  items,
  meta,
  isTurnActive,
  depth = 0,
  runningSubagentToolCallIds,
  forceExpanded = false,
  disclosureValues,
  setDisclosureValue
}: {
  items: readonly WorkedItem[]
  meta: TurnMeta
  isTurnActive: boolean
  depth?: number
  runningSubagentToolCallIds: readonly string[]
  forceExpanded?: boolean
  disclosureValues: TranscriptDisclosureValues
  setDisclosureValue: (key: string, expanded: boolean) => void
}) {
  return (
    <>
      {items.map((workedItem) => {
        switch (workedItem.type) {
          case "text":
            return (
              <StreamingMarkdown
                key={`text:${workedItem.id}`}
                markdown={workedItem.markdown}
                className="text-muted-foreground"
              />
            )
          case "toolGroup":
            return (
              <ToolGroup
                key={`group:${workedItem.id}`}
                calls={workedItem.calls}
                isTurnActive={isTurnActive}
                autoExpanded={
                  depth === 0 &&
                  isTurnActive &&
                  isTrailingToolGroup(
                    meta,
                    workedItem.calls[workedItem.calls.length - 1]?.toolCallId ?? ""
                  )
                }
                forceExpanded={forceExpanded}
                disclosureValues={disclosureValues}
                setDisclosureValue={setDisclosureValue}
              />
            )
          case "subagent":
            return depth < 3 ? (
              <SubagentSection
                key={`subagent:${workedItem.id}`}
                call={workedItem.call}
                meta={meta}
                isTurnActive={isTurnActive}
                depth={depth + 1}
                runningSubagentToolCallIds={runningSubagentToolCallIds}
                forceExpanded={forceExpanded}
                disclosureValues={disclosureValues}
                setDisclosureValue={setDisclosureValue}
              />
            ) : (
              <ToolCallRow
                key={`subagent-row:${workedItem.id}`}
                call={workedItem.call}
                isTurnActive={isTurnActive}
                forceExpanded={forceExpanded}
                disclosureValues={disclosureValues}
                setDisclosureValue={setDisclosureValue}
              />
            )
        }
      })}
    </>
  )
}

function SubagentSection({
  call,
  meta,
  isTurnActive,
  depth,
  runningSubagentToolCallIds,
  forceExpanded = false,
  disclosureValues,
  setDisclosureValue
}: {
  call: ToolCallInfo
  meta: TurnMeta
  isTurnActive: boolean
  depth: number
  runningSubagentToolCallIds: readonly string[]
  forceExpanded?: boolean
  disclosureValues: TranscriptDisclosureValues
  setDisclosureValue: (key: string, expanded: boolean) => void
}) {
  const bucket = meta.subagents[call.toolCallId]
  const isRunning =
    (isTurnActive && !isSettled(call)) || runningSubagentToolCallIds.includes(call.toolCallId)
  const disclosureKey = subagentDisclosureKey(call.toolCallId)
  const expanded = disclosureValues[disclosureKey] ?? isRunning
  const hasAutoCollapsed = useRef(false)
  const items = bucket == null ? [] : groupedItems(meta, bucket.entries)

  useEffect(() => {
    if (forceExpanded) {
      return
    }
    if (isRunning) {
      return
    }
    if (!hasAutoCollapsed.current) {
      hasAutoCollapsed.current = true
      setDisclosureValue(disclosureKey, false)
    }
  }, [disclosureKey, forceExpanded, isRunning, setDisclosureValue])

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <button
        type="button"
        onClick={() => setDisclosureValue(disclosureKey, forceExpanded ? true : !expanded)}
        className="text-muted-foreground flex cursor-default items-center gap-2 text-left text-sm outline-none"
      >
        <WandSparklesIcon className="size-3.5 shrink-0" />
        <span className={cn("min-w-0 flex-1 truncate", isRunning && "animate-pulse")}>
          {call.title?.trim() === "" || call.title == null ? "Agent" : call.title}
        </span>
        {call.status === "failed" && (
          <CircleXIcon className="size-3 text-[var(--herdman-status-error)]" />
        )}
        {call.status === "cancelled" && (
          <CircleSlashIcon className="text-muted-foreground size-3" />
        )}
        <ChevronRightIcon
          className={cn(
            "text-muted-foreground/60 size-3 transition-transform",
            expanded && "rotate-90"
          )}
        />
      </button>
      {expanded && (
        <div className="flex flex-col gap-3 pl-6">
          <TranscriptItems
            items={items}
            meta={meta}
            isTurnActive={isTurnActive}
            depth={depth}
            runningSubagentToolCallIds={runningSubagentToolCallIds}
            forceExpanded={forceExpanded}
            disclosureValues={disclosureValues}
            setDisclosureValue={setDisclosureValue}
          />
          {isRunning && bucket?.isThinking === true && <ShimmerText>Thinking…</ShimmerText>}
          {isRunning && items.length === 0 && bucket?.isThinking !== true && (
            <ShimmerText>Starting agent…</ShimmerText>
          )}
        </div>
      )}
    </div>
  )
}
