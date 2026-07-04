import type { ConversationItem } from "@herdman/api"
import { ArrowDownIcon, TriangleAlertIcon } from "lucide-react"
import {
  memo,
  type ReactNode,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState
} from "react"

import { cn } from "../../lib/cn"
import type { TurnMeta } from "../../lib/queries"
import { AssistantTurn } from "./AssistantTurn"

// A right-aligned user prompt bubble (ConversationItemView.swift).
export function UserMessage({ text }: { text: string }) {
  return (
    <div className="flex justify-end pl-10">
      <div className="bg-bubble rounded-[14px] px-3 py-2 text-sm whitespace-pre-wrap">{text}</div>
    </div>
  )
}

const TranscriptItem = memo(function TranscriptItem({
  item,
  meta
}: {
  item: ConversationItem
  meta?: TurnMeta
}) {
  if (item.role === "user") return <UserMessage text={item.text} />
  if (item.role === "assistant") return <AssistantTurn item={item} meta={meta} />
  return null
})

export function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="flex items-center gap-2 rounded-lg bg-[color-mix(in_srgb,var(--herdman-status-error)_10%,transparent)] p-2.5 text-sm text-[var(--herdman-status-error)]">
      <TriangleAlertIcon className="size-4 shrink-0" />
      {message}
    </div>
  )
}

// Auto-follow stays engaged only while the very end of the content is in view
// (within this many pixels of the viewport bottom) — so scrolling up even
// slightly disengages it instantly. Kept just above zero so the rubber-band
// rebound after an over-scroll doesn't briefly flash the scroll-to-bottom button.
const AT_BOTTOM_THRESHOLD = 2
// When scrolling back DOWN, re-engage auto-follow once within this distance of
// the end. Unpinning is decided by scroll DIRECTION (see handleScroll), so
// scrolling up mid-stream disengages instead of snapping back.
const REPIN_DISTANCE = 40

// The streaming transcript: opens pinned to the end of the history (no scroll
// animation), tracks whether the user is pinned to the bottom, auto-scrolls on
// stream growth only while pinned, floats the composer overlay over the bottom
// with a gradient mask, and offers a scroll-to-bottom button when unpinned
// (SessionView.swift chatArea).
export function Transcript({
  conversation,
  turnMeta,
  errorMessage,
  composerOverlay,
  composerHeight,
  streamFingerprint
}: {
  conversation: readonly ConversationItem[]
  turnMeta?: Record<string, TurnMeta>
  errorMessage?: string
  composerOverlay: ReactNode
  composerHeight: number
  streamFingerprint: string
}) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const [isAtBottom, setIsAtBottom] = useState(true)
  const isAtBottomRef = useRef(true)
  const lastTopRef = useRef(0)

  const scrollToBottom = useCallback((smooth: boolean) => {
    const container = scrollRef.current
    if (container == null) return
    container.scrollTo({ top: container.scrollHeight, behavior: smooth ? "smooth" : "auto" })
    // Markdown layout can grow on the next frame while streaming; a deferred
    // scroll keeps the real bottom aligned.
    requestAnimationFrame(() => {
      container.scrollTo({ top: container.scrollHeight, behavior: smooth ? "smooth" : "auto" })
    })
  }, [])

  const handleScroll = () => {
    const container = scrollRef.current
    if (container == null) return
    const top = container.scrollTop
    const distance = container.scrollHeight - top - container.clientHeight
    const prevTop = lastTopRef.current
    lastTopRef.current = top
    // At the end (incl. the rubber-band rebound after an over-scroll) — stay
    // pinned, keep the button hidden. Otherwise a decrease in offset means the
    // user dragged up (auto-follow/content growth only ever move it down) —
    // disengage; re-engage only while scrolling back down toward the end.
    let pinned = isAtBottomRef.current
    if (distance <= AT_BOTTOM_THRESHOLD) pinned = true
    else if (top < prevTop - 1) pinned = false
    else if (top > prevTop && distance <= REPIN_DISTANCE) pinned = true
    isAtBottomRef.current = pinned
    setIsAtBottom(pinned)
  }

  // Open at the end of the history — jump there before first paint, no
  // scroll animation. History that loads later is pinned by the
  // streamFingerprint effect below (isAtBottom starts true).
  useLayoutEffect(() => {
    const container = scrollRef.current
    if (container == null) return
    container.scrollTop = container.scrollHeight
    lastTopRef.current = container.scrollTop
  }, [])

  // Follow the stream while pinned; never yank the user down while they're
  // reading earlier history.
  useEffect(() => {
    if (isAtBottomRef.current) scrollToBottom(false)
  }, [streamFingerprint, scrollToBottom])

  // Keep pinned when the composer grows (queue expands, textarea grows).
  useEffect(() => {
    if (isAtBottomRef.current) scrollToBottom(false)
  }, [composerHeight, scrollToBottom])

  return (
    <div className="relative min-h-0 flex-1">
      <div
        ref={scrollRef}
        onScroll={handleScroll}
        className="herdman-scrollbar h-full overflow-y-auto"
      >
        <div
          className="mx-auto flex max-w-[880px] flex-col gap-5 px-6 pt-7"
          style={{ paddingBottom: composerHeight + 24 }}
        >
          {conversation.map((item) => (
            <TranscriptItem key={item.id} item={item} meta={turnMeta?.[item.id]} />
          ))}
          {errorMessage != null && <ErrorBanner message={errorMessage} />}
        </div>
      </div>

      {!isAtBottom && (
        <button
          type="button"
          aria-label="Scroll to bottom"
          title="Scroll to bottom"
          onClick={() => scrollToBottom(true)}
          className={cn(
            "absolute left-1/2 z-20 flex size-7 -translate-x-1/2 cursor-default items-center justify-center rounded-full border outline-none",
            "bg-[var(--herdman-popover-bg)] text-[var(--herdman-popover-muted-fg)]",
            "border-[var(--herdman-popover-border)] shadow-[var(--herdman-popover-shadow)]"
          )}
          style={{ bottom: composerHeight + 4 }}
        >
          <ArrowDownIcon className="size-3.5" />
        </button>
      )}

      <div className="absolute inset-x-0 bottom-0 z-10">
        <div className="pointer-events-none absolute inset-0 bg-gradient-to-b from-transparent via-[color-mix(in_srgb,var(--background)_90%,transparent)] to-[var(--background)]" />
        {composerOverlay}
      </div>
    </div>
  )
}
