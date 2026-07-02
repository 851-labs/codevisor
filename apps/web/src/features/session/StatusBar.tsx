import { PanelBottomIcon } from "lucide-react"
import type { PointerEvent as ReactPointerEvent } from "react"
import { useRef } from "react"

import { Kbd } from "../../components/ui/kbd"
import { cn } from "../../lib/cn"
import type { UsageInfo } from "../../lib/session-events"

function abbreviate(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`
  return `${value}`
}

export function formatCost(amount: number, currency: string | undefined): string {
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency",
      currency: currency ?? "USD",
      maximumFractionDigits: amount < 1 ? 4 : 2
    }).format(amount)
  } catch {
    return amount.toFixed(4)
  }
}

export function formatTokens(used: number, size: number | undefined): string {
  if (size != null && size > 0) return `${abbreviate(used)} / ${abbreviate(size)} tokens`
  return `${abbreviate(used)} tokens`
}

// The status bar pinned under the chat: cost + token usage on the left, the
// bottom-panel toggle on the right. When the terminal panel is open, dragging
// the bar resizes it (TerminalPanel.swift SessionStatusBar).
export function StatusBar({
  usage,
  terminalVisible,
  onToggleTerminal,
  onResizeTerminal
}: {
  usage?: UsageInfo
  terminalVisible: boolean
  onToggleTerminal: () => void
  onResizeTerminal: (deltaY: number) => void
}) {
  const dragStartY = useRef<number | undefined>(undefined)

  const handlePointerDown = (pointerEvent: ReactPointerEvent<HTMLDivElement>) => {
    if (!terminalVisible) return
    dragStartY.current = pointerEvent.clientY
    pointerEvent.currentTarget.setPointerCapture(pointerEvent.pointerId)
  }

  const handlePointerMove = (pointerEvent: ReactPointerEvent<HTMLDivElement>) => {
    if (dragStartY.current == null) return
    onResizeTerminal(dragStartY.current - pointerEvent.clientY)
    dragStartY.current = pointerEvent.clientY
  }

  const handlePointerUp = () => {
    dragStartY.current = undefined
  }

  return (
    <div
      className={cn(
        "border-border-opaque bg-background flex h-7 shrink-0 items-center gap-3 border-t px-2.5",
        terminalVisible && "border-b cursor-ns-resize"
      )}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
    >
      {usage != null && (usage.costAmount != null || usage.used != null) && (
        <div className="text-muted-foreground flex items-center gap-3 text-xs">
          {usage.costAmount != null && (
            <span>{formatCost(usage.costAmount, usage.costCurrency)}</span>
          )}
          {usage.used != null && <span>{formatTokens(usage.used, usage.size)}</span>}
        </div>
      )}
      <span className="flex-1" />
      <button
        type="button"
        aria-label="Toggle bottom panel (⌘J)"
        title="Toggle bottom panel (⌘J)"
        onClick={onToggleTerminal}
        className={cn(
          "flex cursor-default items-center gap-1.5 rounded px-1 outline-none",
          terminalVisible ? "text-foreground" : "text-muted-foreground hover:text-foreground"
        )}
      >
        <PanelBottomIcon className="size-4" />
        <Kbd>⌘J</Kbd>
      </button>
    </div>
  )
}
