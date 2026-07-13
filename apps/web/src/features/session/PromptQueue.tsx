import type { PromptQueueItem } from "@codevisor/api"
import {
  CheckIcon,
  ChevronRightIcon,
  ListStartIcon,
  PencilIcon,
  Trash2Icon,
  XIcon
} from "lucide-react"
import { useState } from "react"

import { Input } from "../../components/ui/input"
import { cn } from "../../lib/cn"
import { useDeleteQueuedPrompt, useUpdateQueuedPrompt } from "../../lib/queries"

export function queuedPromptUpdateText(text: string): string | undefined {
  const trimmed = text.trim()
  return trimmed === "" ? undefined : trimmed
}

// The queued-prompts card above the composer: header with count, rows with
// always-visible edit/delete actions, inline editing (SessionView.swift PromptQueueView).
export function PromptQueue({
  sessionId,
  queue,
  isExpanded,
  onToggleExpanded
}: {
  sessionId: string
  queue: readonly PromptQueueItem[]
  isExpanded: boolean
  onToggleExpanded: () => void
}) {
  const [editingId, setEditingId] = useState<string>()
  const [editingText, setEditingText] = useState("")
  const updateQueued = useUpdateQueuedPrompt()
  const deleteQueued = useDeleteQueuedPrompt()

  const countText = queue.length === 1 ? "1 message" : `${queue.length} messages`
  const commitEdit = (item: PromptQueueItem) => {
    const text = queuedPromptUpdateText(editingText)
    if (text != null) updateQueued.mutate({ sessionId, queueItemId: item.id, text })
    setEditingId(undefined)
  }

  return (
    <div className="rounded-[10px] border border-[var(--codevisor-separator)] bg-[color-mix(in_srgb,var(--codevisor-composer-bg)_96%,transparent)] p-2.5">
      <button
        type="button"
        onClick={onToggleExpanded}
        className="flex w-full cursor-default items-center gap-2 outline-none"
      >
        <ChevronRightIcon
          className={cn(
            "text-muted-foreground/60 size-3 transition-transform",
            isExpanded && "rotate-90"
          )}
        />
        <span className="text-xs font-semibold">Queue</span>
        <span className="text-muted-foreground text-xs">{countText}</span>
      </button>
      {isExpanded && (
        <div className="mt-1.5 flex flex-col gap-1.5">
          {queue.map((item) =>
            editingId === item.id ? (
              <div key={item.id} className="flex items-center gap-2 py-0.5 text-xs">
                <Input
                  value={editingText}
                  autoFocus
                  className="h-6 border-transparent px-0 text-xs focus-visible:border-transparent focus-visible:ring-0"
                  onChange={(changeEvent) => setEditingText(changeEvent.target.value)}
                  onKeyDown={(keyEvent) => {
                    if (keyEvent.key === "Enter") {
                      commitEdit(item)
                    }
                    if (keyEvent.key === "Escape") setEditingId(undefined)
                  }}
                />
                <button
                  type="button"
                  aria-label="Save"
                  title="Save"
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => commitEdit(item)}
                >
                  <CheckIcon className="size-3.5" />
                </button>
                <button
                  type="button"
                  aria-label="Cancel"
                  title="Cancel"
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => setEditingId(undefined)}
                >
                  <XIcon className="size-3.5" />
                </button>
              </div>
            ) : (
              <div key={item.id} className="flex items-center gap-2 text-xs">
                <ListStartIcon className="text-muted-foreground/60 size-3.5 shrink-0" />
                <span className="text-muted-foreground line-clamp-2 min-w-0 flex-1">
                  {item.text}
                </span>
                <button
                  type="button"
                  aria-label="Edit queued message"
                  title="Edit queued message"
                  className="text-muted-foreground hover:text-foreground inline-flex shrink-0"
                  onClick={() => {
                    setEditingId(item.id)
                    setEditingText(item.text)
                  }}
                >
                  <PencilIcon className="size-3" />
                </button>
                <button
                  type="button"
                  aria-label="Remove queued message"
                  title="Remove queued message"
                  className="text-muted-foreground hover:text-foreground inline-flex shrink-0"
                  onClick={() => deleteQueued.mutate({ sessionId, queueItemId: item.id })}
                >
                  <Trash2Icon className="size-3" />
                </button>
              </div>
            )
          )}
        </div>
      )}
    </div>
  )
}
