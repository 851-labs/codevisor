import { PanelBottomIcon, PlusIcon, ServerIcon, TerminalIcon, XIcon } from "lucide-react"
import type { PointerEvent as ReactPointerEvent } from "react"
import { useRef } from "react"

import { cn } from "../../lib/cn"

// The status bar pinned under the chat: bottom-panel toggle on the right.
// When the terminal panel is open, dragging the bar resizes it.
export function StatusBar({
  terminalVisible,
  panes,
  selectedPaneId,
  onToggleTerminal,
  onResizeTerminal,
  onSelectPane,
  onClosePane,
  onAddTerminalPane
}: {
  terminalVisible: boolean
  panes: readonly TerminalPaneTab[]
  selectedPaneId: string | undefined
  onToggleTerminal: () => void
  onResizeTerminal: (deltaY: number) => void
  onSelectPane: (id: string) => void
  onClosePane: (id: string) => void
  onAddTerminalPane: () => void
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
        "relative flex h-8 shrink-0 items-center gap-3 border-t border-[var(--codevisor-separator)] bg-background px-2.5",
        terminalVisible && "border-b"
      )}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
    >
      {terminalVisible && (
        <div
          aria-hidden
          className="absolute inset-x-0 top-0 z-20 h-1.5 cursor-ns-resize"
          onPointerDown={handlePointerDown}
        />
      )}
      <div className="flex min-w-0 flex-1 items-center gap-1 overflow-hidden">
        <div className="codevisor-scrollbar flex min-w-0 items-center gap-px overflow-x-auto">
          {panes.map((pane) => {
            const selected = terminalVisible && pane.id === selectedPaneId
            const PaneIcon = pane.attachOnly ? ServerIcon : TerminalIcon
            return (
              <button
                key={pane.id}
                type="button"
                title={pane.name}
                onClick={() => onSelectPane(pane.id)}
                className={cn(
                  "group relative flex h-8 min-w-9 max-w-[168px] shrink-0 cursor-default items-center px-2 text-xs outline-none",
                  selected ? "text-foreground" : "text-muted-foreground hover:text-foreground"
                )}
              >
                {selected ? (
                  <span
                    aria-hidden
                    className="absolute inset-x-0 bottom-0 h-[27px] rounded-t-[6px] bg-[var(--codevisor-separator)]"
                  />
                ) : (
                  <span
                    aria-hidden
                    className="absolute inset-x-0 bottom-[5px] hidden h-[22px] rounded-md bg-foreground/[0.06] group-hover:block"
                  />
                )}
                <span className="relative z-10 flex min-w-0 items-center gap-1">
                  <PaneIcon className="size-3 shrink-0 stroke-[2.4]" />
                  <span className="min-w-0 truncate">{pane.name}</span>
                </span>
                {terminalVisible && (
                  <span
                    role="button"
                    tabIndex={-1}
                    aria-label={`Close ${pane.name}`}
                    title={`Close ${pane.name}`}
                    onClick={(event) => {
                      event.stopPropagation()
                      onClosePane(pane.id)
                    }}
                    className={cn(
                      "relative z-10 ml-0.5 flex size-3.5 shrink-0 items-center justify-center rounded-full text-muted-foreground/70 hover:bg-foreground/[0.14] hover:text-foreground",
                      !selected && "opacity-0 group-hover:opacity-100"
                    )}
                  >
                    <XIcon className="size-2.5 stroke-[2.8]" />
                  </span>
                )}
              </button>
            )
          })}
        </div>
        <button
          type="button"
          aria-label="New terminal"
          title="New terminal"
          onClick={onAddTerminalPane}
          className={cn(
            "flex h-5 w-5 shrink-0 cursor-default items-center justify-center rounded text-muted-foreground outline-none hover:bg-foreground/[0.06] hover:text-foreground",
            !terminalVisible && "pointer-events-none opacity-0"
          )}
        >
          <PlusIcon className="size-2.5 stroke-[2.8]" />
        </button>
      </div>
      <button
        type="button"
        aria-label="Toggle bottom panel (⌘J)"
        title="Toggle bottom panel (⌘J)"
        onClick={onToggleTerminal}
        className={cn(
          "flex h-5 w-6 shrink-0 cursor-default items-center justify-center rounded outline-none hover:bg-foreground/[0.06]",
          terminalVisible ? "text-foreground" : "text-muted-foreground hover:text-foreground"
        )}
      >
        <PanelBottomIcon className="size-3.5 stroke-[2.4]" />
      </button>
    </div>
  )
}

export interface TerminalPaneTab {
  id: string
  name: string
  attachOnly?: boolean
}
