import {
  CheckIcon,
  ChevronRightIcon,
  CircleSlashIcon,
  CircleQuestionMarkIcon,
  FileEditIcon,
  FileSymlinkIcon,
  FileTextIcon,
  GlobeIcon,
  SearchIcon,
  SquareTerminalIcon,
  TrashIcon,
  WandSparklesIcon,
  WrenchIcon,
  XIcon
} from "lucide-react"
import { type CSSProperties, useEffect, useMemo, useRef } from "react"

import { cn } from "../../lib/cn"
import type { ContentBlockInfo, ToolCallContentInfo, ToolCallInfo } from "../../lib/session-events"

export type ToolDisclosureValues = Record<string, boolean>

export function toolGroupDisclosureKey(firstToolCallId: string): string {
  return `toolGroup:${firstToolCallId}`
}

export function toolCallDisclosureKey(toolCallId: string): string {
  return `toolCall:${toolCallId}`
}

function iconForSymbol(symbol: string) {
  switch (symbol) {
    case "doc.text":
      return FileTextIcon
    case "magnifyingglass":
      return SearchIcon
    case "pencil":
      return FileEditIcon
    case "arrow.right.doc.on.clipboard":
      return FileSymlinkIcon
    case "trash":
      return TrashIcon
    case "terminal":
      return SquareTerminalIcon
    case "globe":
      return GlobeIcon
    case "questionmark.bubble":
      return CircleQuestionMarkIcon
    case "wand.and.sparkles":
      return WandSparklesIcon
    case "wrench.and.screwdriver":
    default:
      return WrenchIcon
  }
}

// Summed +N/−N across the call's per-path diff stats; re-renders (and thus
// counts up) as streamed updates merge in.
function DiffBadge({ call }: { call: ToolCallInfo }) {
  const totals = diffTotals(call)
  if (totals == null) return null
  return (
    <span className="shrink-0 font-mono text-xs tabular-nums">
      <span className="text-[var(--herdman-diff-add-fg)]">+{totals.added}</span>{" "}
      <span className="text-[var(--herdman-diff-del-fg)]">−{totals.removed}</span>
    </span>
  )
}

function diffTotals(call: ToolCallInfo): { added: number; removed: number } | undefined {
  if (call.diffStats != null && call.diffStats.length > 0) {
    let added = 0
    let removed = 0
    for (const stat of call.diffStats) {
      added += stat.added
      removed += stat.removed
    }
    return { added, removed }
  }

  const diffs = call.content?.filter((content) => content.type === "diff")
  if (diffs == null || diffs.length === 0) return undefined

  return diffs.reduce(
    (totals, diff) => {
      for (const row of diffRows(diff.oldText, diff.newText)) {
        if (row.kind === "added") totals.added += 1
        else if (row.kind === "removed") totals.removed += 1
      }
      return totals
    },
    { added: 0, removed: 0 }
  )
}

function isSettled(call: ToolCallInfo): boolean {
  return call.status === "completed" || call.status === "failed" || call.status === "cancelled"
}

function displayTitle(call: ToolCallInfo): string {
  const title = call.title?.trim() ?? ""
  if (call.kind !== "edit" || isSettled(call) || diffTotals(call) != null) {
    return title === "" ? "Working…" : title
  }
  return title === "" || !title.includes(" ") ? "Editing file…" : title
}

function hasRenderableContent(call: ToolCallInfo): boolean {
  return (call.content?.length ?? 0) > 0 || call.rawOutput != null
}

function hasOnlyDiffContent(call: ToolCallInfo): boolean {
  return (
    call.rawOutput == null &&
    call.content != null &&
    call.content.length > 0 &&
    call.content.every((content) => content.type === "diff")
  )
}

function shouldShowStatusBadge(call: ToolCallInfo): boolean {
  return (
    isSettled(call) &&
    (call.kind === "execute" || call.status === "failed" || call.status === "cancelled")
  )
}

function labelForKind(kind: string | undefined): string {
  switch (kind) {
    case "execute":
      return "Shell"
    case "read":
      return "File"
    case "edit":
      return "Diff"
    case "search":
      return "Search"
    case "web_search":
      return "Sources"
    case "fetch":
      return "Fetch"
    case "question":
      return "Answer"
    default:
      return "Output"
  }
}

function rawValueText(value: unknown): string | undefined {
  if (value == null) return undefined
  if (typeof value === "string") return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}

export function ToolCallRow({
  call,
  isTurnActive = false,
  forceExpanded = false,
  disclosureValues = {},
  setDisclosureValue = () => undefined
}: {
  call: ToolCallInfo
  isTurnActive?: boolean
  forceExpanded?: boolean
  disclosureValues?: ToolDisclosureValues
  setDisclosureValue?: (key: string, expanded: boolean) => void
}) {
  const hasContent = hasRenderableContent(call)
  const disclosureKey = toolCallDisclosureKey(call.toolCallId)
  const expanded = forceExpanded || (disclosureValues[disclosureKey] ?? false)
  useEffect(() => {
    if (forceExpanded) setDisclosureValue(disclosureKey, true)
  }, [disclosureKey, forceExpanded, setDisclosureValue])
  return (
    <div className="flex min-w-0 flex-col gap-1.5">
      <button
        type="button"
        disabled={!hasContent}
        onClick={() => setDisclosureValue(disclosureKey, forceExpanded ? true : !expanded)}
        className="text-muted-foreground flex cursor-default items-center gap-1.5 text-left text-sm outline-none"
      >
        <span
          className={cn(
            "min-w-0 flex-1 truncate",
            isTurnActive && !isSettled(call) && "animate-pulse"
          )}
        >
          {displayTitle(call)}
        </span>
        <DiffBadge call={call} />
        {hasContent && (
          <ChevronRightIcon
            className={cn(
              "text-muted-foreground/60 size-3 transition-transform",
              expanded && "rotate-90"
            )}
          />
        )}
      </button>
      {expanded && hasContent && (
        <>
          {hasOnlyDiffContent(call) ? (
            <div className="flex min-w-0 flex-col gap-2">
              {call.content?.map((content, index) =>
                content.type === "diff" ? (
                  <DiffBlock
                    key={index}
                    path={content.path}
                    oldText={content.oldText}
                    newText={content.newText}
                  />
                ) : null
              )}
            </div>
          ) : (
            <ToolCallContentCard call={call} />
          )}
        </>
      )}
    </div>
  )
}

type ToolCategory =
  | "edit"
  | "read"
  | "search"
  | "webSearch"
  | "execute"
  | "fetch"
  | "delete"
  | "move"
  | "agent"
  | "question"
  | "other"

function category(kind: string | undefined): ToolCategory {
  switch (kind) {
    case "edit":
      return "edit"
    case "read":
      return "read"
    case "search":
      return "search"
    case "web_search":
      return "webSearch"
    case "execute":
      return "execute"
    case "fetch":
      return "fetch"
    case "delete":
      return "delete"
    case "move":
      return "move"
    case "agent":
      return "agent"
    case "question":
      return "question"
    default:
      return "other"
  }
}

function phrase(categoryName: ToolCategory, count: number): string {
  const single = count === 1
  switch (categoryName) {
    case "read":
      return single ? "read a file" : `read ${count} files`
    case "search":
      return "searched code"
    case "webSearch":
      return single ? "searched the web" : `ran ${count} web searches`
    case "execute":
      return single ? "ran a command" : `ran ${count} commands`
    case "edit":
      return single ? "edited a file" : `edited ${count} files`
    case "fetch":
      return single ? "fetched a resource" : `fetched ${count} resources`
    case "delete":
      return single ? "deleted a file" : `deleted ${count} files`
    case "move":
      return single ? "moved a file" : `moved ${count} files`
    case "agent":
      return single ? "ran an agent" : `ran ${count} agents`
    case "question":
      return single ? "asked a question" : `asked ${count} questions`
    case "other":
      return single ? "ran a tool" : `ran ${count} tools`
  }
}

function joinPhrases(phrases: readonly string[]): string {
  if (phrases.length === 0) return "ran tools"
  if (phrases.length === 1) return phrases[0] ?? "ran tools"
  if (phrases.length === 2) return `${phrases[0]} and ${phrases[1]}`
  return `${phrases.slice(0, -1).join(", ")}, and ${phrases.at(-1)}`
}

export function describeCalls(calls: readonly ToolCallInfo[]): string {
  if (calls.length === 0) return ""
  const order: ToolCategory[] = []
  const counts = new Map<ToolCategory, number>()
  for (const call of calls) {
    const callCategory = category(call.kind)
    if (!counts.has(callCategory)) order.push(callCategory)
    counts.set(callCategory, (counts.get(callCategory) ?? 0) + 1)
  }
  const description = joinPhrases(order.map((entry) => phrase(entry, counts.get(entry) ?? 0)))
  return description.charAt(0).toUpperCase() + description.slice(1)
}

export function toolGroupSymbol(calls: readonly ToolCallInfo[]): string {
  // macOS pins the group icon to the first call so the glyph does not flip as
  // more calls stream into the group.
  const firstCategory = category(calls[0]?.kind)

  switch (firstCategory) {
    case "search":
    case "webSearch":
      return "magnifyingglass"
    case "execute":
      return "terminal"
    case "edit":
      return "pencil"
    case "read":
      return "doc.text"
    case "fetch":
      return "globe"
    case "delete":
      return "trash"
    case "move":
      return "arrow.right.doc.on.clipboard"
    case "question":
      return "questionmark.bubble"
    case "agent":
      return "wand.and.sparkles"
    case "other":
      return "wrench.and.screwdriver"
  }
}

export function ToolGroup({
  calls,
  isTurnActive = false,
  autoExpanded = false,
  forceExpanded = false,
  disclosureValues = {},
  setDisclosureValue = () => undefined
}: {
  calls: readonly ToolCallInfo[]
  isTurnActive?: boolean
  autoExpanded?: boolean
  forceExpanded?: boolean
  disclosureValues?: ToolDisclosureValues
  setDisclosureValue?: (key: string, expanded: boolean) => void
}) {
  const disclosureKey = toolGroupDisclosureKey(calls[0]?.toolCallId ?? "")
  const expanded = forceExpanded || (disclosureValues[disclosureKey] ?? autoExpanded)
  const previousAutoExpanded = useRef(autoExpanded)
  const Icon = iconForSymbol(toolGroupSymbol(calls))
  const title = useMemo(() => describeCalls(calls), [calls])

  useEffect(() => {
    if (forceExpanded) setDisclosureValue(disclosureKey, true)
  }, [disclosureKey, forceExpanded, setDisclosureValue])

  useEffect(() => {
    if (previousAutoExpanded.current === autoExpanded) return
    previousAutoExpanded.current = autoExpanded
    setDisclosureValue(disclosureKey, autoExpanded)
  }, [autoExpanded, disclosureKey, setDisclosureValue])

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <button
        type="button"
        onClick={() => setDisclosureValue(disclosureKey, forceExpanded ? true : !expanded)}
        className="text-muted-foreground flex cursor-default items-center gap-2 text-left text-sm outline-none"
      >
        <Icon className="size-3.5 w-4 shrink-0" />
        <span className="min-w-0 truncate">{title}</span>
        <ChevronRightIcon
          className={cn(
            "text-muted-foreground/60 size-3 transition-transform",
            expanded && "rotate-90"
          )}
        />
      </button>
      {expanded && (
        <div className="flex flex-col gap-2 pl-6">
          {calls.map((call) => (
            <ToolCallRow
              key={call.toolCallId}
              call={call}
              isTurnActive={isTurnActive}
              forceExpanded={forceExpanded}
              disclosureValues={disclosureValues}
              setDisclosureValue={setDisclosureValue}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function ToolCallContentCard({ call }: { call: ToolCallInfo }) {
  return (
    <div className="flex w-full min-w-0 flex-col gap-2 rounded-lg bg-[var(--herdman-card-bg)] p-2.5">
      <div className="text-muted-foreground text-xs font-semibold">{labelForKind(call.kind)}</div>
      {call.content?.map((content, index) => (
        <ToolCallContent key={index} content={content} />
      ))}
      {call.rawOutput != null && <MonospaceBlock text={rawValueText(call.rawOutput) ?? ""} />}
      {shouldShowStatusBadge(call) && (
        <div className="flex justify-end">
          <StatusBadge status={call.status} />
        </div>
      )}
    </div>
  )
}

function ToolCallContent({ content }: { content: ToolCallContentInfo }) {
  switch (content.type) {
    case "content":
      return <ContentBlock block={content.content} />
    case "diff":
      return <DiffBlock path={content.path} oldText={content.oldText} newText={content.newText} />
    case "terminal":
      return <MonospaceBlock text={`Terminal ${content.terminalId}`} muted />
  }
}

function ContentBlock({ block }: { block: ContentBlockInfo }) {
  switch (block.type) {
    case "text":
      return <MonospaceBlock text={block.text} />
    case "resource_link":
      return <ResourceLink block={block} />
  }
}

function ResourceLink({ block }: { block: Extract<ContentBlockInfo, { type: "resource_link" }> }) {
  const url = parseResourceLinkUrl(block.uri)
  const label = resourceLinkLabel(block)
  if (url == null) {
    return <span className="text-muted-foreground truncate text-xs">{label}</span>
  }

  return (
    <a
      href={block.uri}
      target="_blank"
      rel="noreferrer"
      title={block.uri}
      className="flex min-w-0 items-start gap-1.5"
    >
      <GlobeIcon className="text-muted-foreground/70 mt-0.5 size-3 shrink-0" />
      <span className="flex min-w-0 flex-col">
        <span className="truncate text-xs text-[var(--herdman-accent)]">{label}</span>
        <span className="text-muted-foreground truncate text-[11px]">{url.host}</span>
      </span>
    </a>
  )
}

export function resourceLinkLabel({
  name,
  title,
  uri
}: Pick<Extract<ContentBlockInfo, { type: "resource_link" }>, "name" | "title" | "uri">) {
  const label = title ?? name
  return label === "" ? uri : label
}

export function parseResourceLinkUrl(uri: string): URL | undefined {
  try {
    return new URL(uri)
  } catch {
    return undefined
  }
}

function MonospaceBlock({ text, muted = false }: { text: string; muted?: boolean }) {
  return (
    <pre
      className={cn(
        "herdman-selectable max-h-80 overflow-auto whitespace-pre-wrap break-words text-xs",
        "font-mono leading-relaxed",
        muted ? "text-muted-foreground" : "text-foreground"
      )}
    >
      {text}
    </pre>
  )
}

function DiffBlock({
  path,
  oldText,
  newText
}: {
  path: string
  oldText?: string
  newText: string
}) {
  const rows = useMemo(() => {
    const dedented = dedentDiffTexts(oldText, newText)
    return diffRows(dedented.oldText, dedented.newText)
  }, [oldText, newText])
  const maxLine = rows.reduce((max, row) => Math.max(max, row.oldLine ?? 0, row.newLine ?? 0), 1)
  const gutterWidth = `${Math.max(2, String(maxLine).length)}ch`

  return (
    <div
      className="herdman-selectable max-h-80 overflow-auto rounded-lg border border-[var(--border)] bg-[var(--herdman-code-bg)] font-mono text-xs leading-relaxed"
      title={path}
    >
      <div className="min-w-full py-1">
        {rows.map((row, index) => (
          <div
            key={index}
            className={cn(
              "grid grid-cols-[var(--old-gutter)_var(--new-gutter)_8px_1fr] gap-1.5 px-2 py-px",
              row.kind === "removed" &&
                "bg-[color-mix(in_srgb,var(--herdman-diff-del-fg)_10%,transparent)]",
              row.kind === "added" &&
                "bg-[color-mix(in_srgb,var(--herdman-diff-add-fg)_10%,transparent)]"
            )}
            style={
              {
                "--old-gutter": gutterWidth,
                "--new-gutter": gutterWidth
              } as CSSProperties
            }
          >
            <span className={lineNumberClass(row.kind)}>{row.oldLine ?? ""}</span>
            <span className={lineNumberClass(row.kind)}>{row.newLine ?? ""}</span>
            <span className={markerClass(row.kind)}>{markerFor(row.kind)}</span>
            <span className="whitespace-pre">{row.text === "" ? " " : row.text}</span>
          </div>
        ))}
      </div>
    </div>
  )
}

type DiffRow = {
  kind: "context" | "removed" | "added"
  oldLine?: number
  newLine?: number
  text: string
}

function splitLines(text: string | undefined): string[] {
  if (text == null || text === "") return []
  return text.endsWith("\n") ? text.slice(0, -1).split("\n") : text.split("\n")
}

export function dedentDiffTexts(
  oldText: string | undefined,
  newText: string
): { oldText: string | undefined; newText: string } {
  const prefix = commonIndent([...splitLines(oldText), ...splitLines(newText)])
  if (prefix === "") return { oldText, newText }
  return {
    oldText: oldText == null ? undefined : stripIndentPrefix(prefix, oldText),
    newText: stripIndentPrefix(prefix, newText)
  }
}

function commonIndent(lines: readonly string[]): string {
  let common: string | undefined
  for (const line of lines) {
    if (line === "" || line.trim() === "") continue
    const indent = line.match(/^[ \t]*/)?.[0] ?? ""
    common = common == null ? indent : sharedPrefix(common, indent)
    if (common === "") break
  }
  return common ?? ""
}

function sharedPrefix(first: string, second: string): string {
  let index = 0
  while (index < first.length && index < second.length && first[index] === second[index]) {
    index += 1
  }
  return first.slice(0, index)
}

function stripIndentPrefix(prefix: string, text: string): string {
  return text
    .split("\n")
    .map((line) => {
      if (line.startsWith(prefix)) return line.slice(prefix.length)
      return line.trim() === "" ? "" : line
    })
    .join("\n")
}

export function diffRows(oldText: string | undefined, newText: string): DiffRow[] {
  const oldLines = splitLines(oldText)
  const newLines = splitLines(newText)
  if (oldLines.length === 0) {
    return newLines.map((text, index) => ({ kind: "added", newLine: index + 1, text }))
  }

  const table: number[][] = Array.from({ length: oldLines.length + 1 }, () =>
    Array.from({ length: newLines.length + 1 }, () => 0)
  )
  for (let oldIndex = oldLines.length - 1; oldIndex >= 0; oldIndex -= 1) {
    for (let newIndex = newLines.length - 1; newIndex >= 0; newIndex -= 1) {
      table[oldIndex]![newIndex] =
        oldLines[oldIndex] === newLines[newIndex]
          ? (table[oldIndex + 1]?.[newIndex + 1] ?? 0) + 1
          : Math.max(table[oldIndex + 1]?.[newIndex] ?? 0, table[oldIndex]?.[newIndex + 1] ?? 0)
    }
  }

  const rows: DiffRow[] = []
  let oldIndex = 0
  let newIndex = 0
  while (oldIndex < oldLines.length || newIndex < newLines.length) {
    if (oldLines[oldIndex] === newLines[newIndex]) {
      rows.push({
        kind: "context",
        oldLine: oldIndex + 1,
        newLine: newIndex + 1,
        text: oldLines[oldIndex] ?? ""
      })
      oldIndex += 1
      newIndex += 1
    } else if (
      newIndex >= newLines.length ||
      (oldIndex < oldLines.length &&
        (table[oldIndex + 1]?.[newIndex] ?? 0) >= (table[oldIndex]?.[newIndex + 1] ?? 0))
    ) {
      rows.push({ kind: "removed", oldLine: oldIndex + 1, text: oldLines[oldIndex] ?? "" })
      oldIndex += 1
    } else {
      rows.push({ kind: "added", newLine: newIndex + 1, text: newLines[newIndex] ?? "" })
      newIndex += 1
    }
  }
  return rows
}

function markerFor(kind: DiffRow["kind"]): string {
  switch (kind) {
    case "added":
      return "+"
    case "removed":
      return "-"
    case "context":
      return " "
  }
}

function markerClass(kind: DiffRow["kind"]): string {
  switch (kind) {
    case "added":
      return "text-[var(--herdman-diff-add-fg)]"
    case "removed":
      return "text-[var(--herdman-diff-del-fg)]"
    case "context":
      return "text-muted-foreground"
  }
}

function lineNumberClass(kind: DiffRow["kind"]): string {
  return cn(
    "text-right tabular-nums",
    kind === "added" && "text-[var(--herdman-diff-add-fg)]",
    kind === "removed" && "text-[var(--herdman-diff-del-fg)]",
    kind === "context" && "text-muted-foreground/70"
  )
}

function StatusBadge({ status }: { status: string | undefined }) {
  switch (status) {
    case "completed":
      return (
        <span className="flex items-center gap-1 text-xs text-[var(--herdman-status-ok)]">
          <CheckIcon className="size-3" />
          Success
        </span>
      )
    case "failed":
      return (
        <span className="flex items-center gap-1 text-xs text-[var(--herdman-status-error)]">
          <XIcon className="size-3" />
          Failed
        </span>
      )
    case "cancelled":
      return (
        <span className="text-muted-foreground flex items-center gap-1 text-xs">
          <CircleSlashIcon className="size-3" />
          Cancelled
        </span>
      )
    default:
      return null
  }
}
