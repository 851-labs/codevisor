import type { PromptQueueItem } from "@herdman/api"
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

// The queued-prompts card above the composer: header with count, rows with
// hover edit/delete, inline editing (SessionView.swift PromptQueueView).
export function PromptQueue({
  sessionId,
  queue
}: {
  sessionId: string
  queue: readonly PromptQueueItem[]
}) {
  const [isExpanded, setIsExpanded] = useState(true)
  const [editingId, setEditingId] = useState<string>()
  const [editingText, setEditingText] = useState("")
  const updateQueued = useUpdateQueuedPrompt()
  const deleteQueued = useDeleteQueuedPrompt()

  const countText = queue.length === 1 ? "1 message" : `${queue.length} messages`

  return (
    <div className="border-border-opaque rounded-[10px] border bg-[var(--herdman-card-bg)] p-2.5">
      <button
        type="button"
        onClick={() => setIsExpanded((expanded) => !expanded)}
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
              <div key={item.id} className="flex items-center gap-2">
                <Input
                  value={editingText}
                  autoFocus
                  className="h-6 text-xs"
                  onChange={(changeEvent) => setEditingText(changeEvent.target.value)}
                  onKeyDown={(keyEvent) => {
                    if (keyEvent.key === "Enter") {
                      updateQueued.mutate({ sessionId, queueItemId: item.id, text: editingText })
                      setEditingId(undefined)
                    }
                    if (keyEvent.key === "Escape") setEditingId(undefined)
                  }}
                />
                <button
                  type="button"
                  aria-label="Save"
                  title="Save"
                  className="text-muted-foreground hover:text-foreground"
                  onClick={() => {
                    updateQueued.mutate({ sessionId, queueItemId: item.id, text: editingText })
                    setEditingId(undefined)
                  }}
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
              <div key={item.id} className="group flex items-center gap-2 text-xs">
                <ListStartIcon className="text-muted-foreground/60 size-3.5 shrink-0" />
                <span className="text-muted-foreground min-w-0 flex-1 truncate">{item.text}</span>
                <button
                  type="button"
                  aria-label="Edit queued message"
                  title="Edit queued message"
                  className="text-muted-foreground hover:text-foreground hidden group-hover:inline-flex"
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
                  className="text-muted-foreground hover:text-foreground hidden group-hover:inline-flex"
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
