import {
  ArrowLeftIcon,
  ArrowUpIcon,
  LoaderCircleIcon,
  PaperclipIcon,
  SquareIcon,
  TargetIcon,
  TriangleAlertIcon,
  XIcon
} from "lucide-react"
import {
  type ClipboardEvent,
  type DragEvent,
  type KeyboardEvent,
  type ReactNode,
  useEffect,
  useMemo,
  useRef,
  useState
} from "react"

import {
  AttachmentLightbox,
  FileChip,
  hasVisualAttachmentPreview,
  isPdfAttachment,
  isVideoAttachment,
  type LightboxItem,
  VisualThumb
} from "../attachments/AttachmentPreview"
import { cn } from "../../lib/cn"
import { type SlashCommand, slashMatchesFor, slashQueryFrom } from "./slash-commands"
import type { ComposerAttachmentItem } from "./useComposerAttachments"
// import type { HarnessUsageLimits } from "@codevisor/api"
// import type { UsageInfo } from "../../lib/session-events"
// import { UsageRingButton } from "./UsageRingButton"

// The chat composer card: a multiline autosize input (Return sends,
// Shift+Return adds a newline) with an inline toolbar holding caller-supplied
// picker chips and the stop/send buttons, plus the slash-command popup.
// Port of ComposerView.swift's ComposerCard.
export function Composer({
  value,
  onValueChange,
  placeholder = "Do anything",
  chips,
  commands = [],
  attachments = [],
  // usage,
  // usageLimits,
  // isLoadingUsageLimits = false,
  // usageLimitsError,
  // onRequestUsageLimits,
  canSend,
  isSending = false,
  isCancelling = false,
  isGoalEditing = false,
  autoFocus = false,
  focusOnTyping = false,
  onAttachFiles,
  onRemoveAttachment,
  onRetryAttachment,
  onSend,
  onEscape,
  onStop
}: {
  value: string
  onValueChange: (next: string) => void
  placeholder?: string
  chips?: ReactNode
  commands?: readonly SlashCommand[]
  attachments?: readonly ComposerAttachmentItem[]
  // usage?: UsageInfo
  // usageLimits?: HarnessUsageLimits
  // isLoadingUsageLimits?: boolean
  // usageLimitsError?: string
  // onRequestUsageLimits?: () => void
  canSend?: boolean
  isSending?: boolean
  isCancelling?: boolean
  isGoalEditing?: boolean
  autoFocus?: boolean
  focusOnTyping?: boolean
  onAttachFiles?: (files: readonly File[]) => void
  onRemoveAttachment?: (id: string) => void
  onRetryAttachment?: (id: string) => void
  onSend: () => void
  onEscape?: () => void
  onStop?: () => void
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [slashSelection, setSlashSelection] = useState(0)
  const [slashDismissed, setSlashDismissed] = useState(false)

  const slashQuery = slashQueryFrom(value)
  const matches = useMemo(() => slashMatchesFor(commands, slashQuery), [commands, slashQuery])
  // The matches actually shown: empty while the menu is dismissed with Escape.
  const visibleMatches = slashDismissed ? [] : matches

  // A new query invalidates both the keyboard selection and any
  // Escape-dismissal of the previous menu.
  useEffect(() => {
    setSlashSelection(0)
    setSlashDismissed(false)
  }, [slashQuery])

  useEffect(() => {
    const textarea = textareaRef.current
    if (textarea == null) return
    textarea.style.height = "auto"
    textarea.style.height = `${Math.min(textarea.scrollHeight, 240)}px`
  }, [value])

  useEffect(() => {
    if (!autoFocus) return
    const textarea = textareaRef.current
    if (textarea == null) return
    textarea.focus()
    textarea.setSelectionRange(textarea.value.length, textarea.value.length)
  }, [autoFocus])

  useEffect(() => {
    if (!focusOnTyping) return

    const handleWindowKeyDown = (event: globalThis.KeyboardEvent) => {
      const textarea = textareaRef.current
      if (
        textarea == null ||
        textarea.disabled ||
        document.activeElement === textarea ||
        !isTypeToFocusKey(event) ||
        hasCompetingTextFocus(event.target) ||
        document.querySelector('[data-popup-open], [role="dialog"]') != null
      ) {
        return
      }

      const selectionStart = textarea.selectionStart ?? textarea.value.length
      const selectionEnd = textarea.selectionEnd ?? selectionStart
      const nextValue =
        textarea.value.slice(0, selectionStart) + event.key + textarea.value.slice(selectionEnd)
      const nextSelection = selectionStart + event.key.length

      event.preventDefault()
      textarea.focus()
      onValueChange(nextValue)
      requestAnimationFrame(() => textarea.setSelectionRange(nextSelection, nextSelection))
    }

    window.addEventListener("keydown", handleWindowKeyDown)
    return () => window.removeEventListener("keydown", handleWindowKeyDown)
  }, [focusOnTyping, onValueChange])

  const hasDraft = value.trim() !== "" || attachments.length > 0
  const sendEnabled = (canSend ?? hasDraft) || visibleMatches.length > 0
  const isSubmittingOnly = isSending && onStop == null

  const acceptSlashCommand = (command: SlashCommand) => {
    onValueChange(`/${command.name} `)
    setSlashSelection(0)
    textareaRef.current?.focus()
  }

  const submitOrAcceptSlash = () => {
    const selected = visibleMatches[Math.min(slashSelection, visibleMatches.length - 1)]
    if (selected != null) {
      acceptSlashCommand(selected)
      return
    }
    if (hasDraft || canSend === true) onSend()
  }

  const sendButton = isSubmittingOnly ? (
    <div
      role="status"
      aria-label="Sending"
      title="Sending..."
      className="flex size-[26px] items-center justify-center rounded-full bg-[color-mix(in_srgb,var(--foreground)_16%,transparent)] text-muted-foreground"
    >
      <LoaderCircleIcon className="size-3.5 animate-spin" />
    </div>
  ) : (
    <button
      type="button"
      aria-label="Send (↩)"
      title="Send (↩)"
      disabled={!sendEnabled}
      onClick={submitOrAcceptSlash}
      className={cn(
        "flex size-[26px] cursor-default items-center justify-center rounded-full outline-none",
        sendEnabled
          ? "bg-[color-mix(in_srgb,var(--foreground)_82%,transparent)] text-primary-foreground hover:bg-[color-mix(in_srgb,var(--foreground)_92%,transparent)]"
          : "bg-[color-mix(in_srgb,var(--foreground)_16%,transparent)] text-muted-foreground/75"
      )}
    >
      <ArrowUpIcon className="size-3.5" strokeWidth={3} />
    </button>
  )

  const handleKeyDown = (keyEvent: KeyboardEvent<HTMLTextAreaElement>) => {
    if (keyEvent.key === "Escape" && onEscape != null) {
      keyEvent.preventDefault()
      onEscape()
      return
    }

    const menuOpen = visibleMatches.length > 0
    if (menuOpen) {
      if (keyEvent.key === "ArrowUp") {
        keyEvent.preventDefault()
        setSlashSelection((index) => (index - 1 + visibleMatches.length) % visibleMatches.length)
        return
      }
      if (keyEvent.key === "ArrowDown") {
        keyEvent.preventDefault()
        setSlashSelection((index) => (index + 1) % visibleMatches.length)
        return
      }
      if (keyEvent.key === "Escape") {
        keyEvent.preventDefault()
        setSlashDismissed(true)
        setSlashSelection(0)
        return
      }
      if (keyEvent.key === "Tab") {
        keyEvent.preventDefault()
        submitOrAcceptSlash()
        return
      }
    }
    if (keyEvent.key === "Enter" && !keyEvent.shiftKey) {
      keyEvent.preventDefault()
      submitOrAcceptSlash()
    }
  }

  const handleFiles = (files: FileList | readonly File[] | null) => {
    if (files == null || onAttachFiles == null) return
    onAttachFiles(Array.from(files))
  }

  const handlePaste = (event: ClipboardEvent<HTMLTextAreaElement>) => {
    const files = Array.from(event.clipboardData.files)
    if (files.length === 0) return
    event.preventDefault()
    handleFiles(files)
  }

  const handleDrop = (event: DragEvent<HTMLDivElement>) => {
    const files = Array.from(event.dataTransfer.files)
    if (files.length === 0) return
    event.preventDefault()
    handleFiles(files)
  }

  return (
    <div
      className="bg-composer relative flex flex-col gap-2.5 rounded-2xl border border-[var(--codevisor-separator)] p-3"
      onDragOver={(event) => {
        if (event.dataTransfer.types.includes("Files")) event.preventDefault()
      }}
      onDrop={handleDrop}
    >
      <div className="flex flex-col gap-1">
        {isGoalEditing && (
          <div className="text-muted-foreground flex items-center gap-1.5 text-xs font-semibold">
            <TargetIcon className="size-3.5" />
            <span>Edit goal</span>
          </div>
        )}
        {attachments.length > 0 && (
          <ComposerAttachmentRow
            attachments={attachments}
            onRemove={onRemoveAttachment}
            onRetry={onRetryAttachment}
          />
        )}
        <div className="relative">
          {visibleMatches.length > 0 && (
            <SlashCommandMenu
              matches={visibleMatches}
              selectedIndex={Math.min(slashSelection, visibleMatches.length - 1)}
              onAccept={acceptSlashCommand}
            />
          )}
          <textarea
            ref={textareaRef}
            rows={1}
            value={value}
            placeholder={placeholder}
            disabled={isSubmittingOnly}
            onChange={(changeEvent) => onValueChange(changeEvent.target.value)}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            className="placeholder:text-muted-foreground/70 max-h-[240px] w-full resize-none bg-transparent text-sm outline-none disabled:opacity-100"
          />
        </div>
      </div>
      <div className="flex items-center gap-2.5">
        {isGoalEditing ? (
          <>
            <span className="text-muted-foreground text-xs">esc to cancel</span>
            <span className="flex-1" />
            <button
              type="button"
              aria-label="Back"
              title="Back - keep current goal (esc)"
              onClick={onEscape}
              className="text-foreground flex size-[26px] cursor-default items-center justify-center rounded-full bg-[color-mix(in_srgb,var(--foreground)_16%,transparent)] outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_22%,transparent)]"
            >
              <ArrowLeftIcon className="size-4" />
            </button>
            {sendButton}
          </>
        ) : (
          <>
            {onAttachFiles != null && (
              <>
                <input
                  ref={fileInputRef}
                  type="file"
                  multiple
                  className="hidden"
                  onChange={(event) => {
                    handleFiles(event.currentTarget.files)
                    event.currentTarget.value = ""
                  }}
                />
                <button
                  type="button"
                  aria-label="Attach files"
                  title="Attach files"
                  onClick={() => fileInputRef.current?.click()}
                  className="text-muted-foreground hover:text-foreground flex size-[26px] cursor-default items-center justify-center rounded-full outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] active:opacity-80"
                >
                  <PaperclipIcon className="size-4" />
                </button>
              </>
            )}
            {chips}
            <span className="flex-1" />
            {/* Usage gauge and popover are temporarily disabled.
            <UsageRingButton
              usage={usage}
              limits={usageLimits}
              isLoadingLimits={isLoadingUsageLimits}
              limitsError={usageLimitsError}
              onRequestLimits={onRequestUsageLimits}
            />
            */}
            {isSending &&
              onStop != null &&
              (isCancelling ? (
                <div
                  role="status"
                  aria-label="Stopping"
                  title="Stopping..."
                  className="text-muted-foreground flex size-[26px] items-center justify-center"
                >
                  <LoaderCircleIcon className="size-3.5 animate-spin" />
                </div>
              ) : (
                <button
                  type="button"
                  aria-label="Stop"
                  title="Stop"
                  onClick={onStop}
                  className="text-muted-foreground hover:text-foreground flex size-[26px] cursor-default items-center justify-center rounded-full border border-[var(--codevisor-separator)] outline-none hover:bg-[color-mix(in_srgb,var(--foreground)_6%,transparent)] active:opacity-80"
                >
                  <SquareIcon className="size-2.5 fill-current" />
                </button>
              ))}
            {(isSubmittingOnly || !isSending || hasDraft) && sendButton}
          </>
        )}
      </div>
    </div>
  )
}

export function isTypeToFocusKey(
  event: Pick<
    globalThis.KeyboardEvent,
    "key" | "ctrlKey" | "metaKey" | "altKey" | "isComposing" | "defaultPrevented"
  >
) {
  return (
    !event.defaultPrevented &&
    !event.isComposing &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.altKey &&
    event.key.length === 1
  )
}

function hasCompetingTextFocus(eventTarget: EventTarget | null) {
  const focused = document.activeElement
  return [eventTarget, focused].some((candidate) => {
    if (!(candidate instanceof HTMLElement)) return false
    return (
      candidate instanceof HTMLInputElement ||
      candidate instanceof HTMLTextAreaElement ||
      candidate instanceof HTMLSelectElement ||
      candidate.isContentEditable ||
      candidate.closest(
        '[contenteditable="true"], [role="textbox"], [role="menu"], [role="listbox"]'
      ) != null
    )
  })
}

function ComposerAttachmentRow({
  attachments,
  onRemove,
  onRetry
}: {
  attachments: readonly ComposerAttachmentItem[]
  onRemove?: (id: string) => void
  onRetry?: (id: string) => void
}) {
  return (
    <div className="codevisor-scrollbar -mx-1 flex gap-2.5 overflow-x-auto px-1 pb-0.5">
      {attachments.map((attachment) => (
        <ComposerAttachmentThumb
          key={attachment.id}
          attachment={attachment}
          onRemove={onRemove}
          onRetry={onRetry}
        />
      ))}
    </div>
  )
}

function ComposerAttachmentThumb({
  attachment,
  onRemove,
  onRetry
}: {
  attachment: ComposerAttachmentItem
  onRemove?: (id: string) => void
  onRetry?: (id: string) => void
}) {
  const [lightboxItem, setLightboxItem] = useState<LightboxItem>()
  const visual = hasVisualAttachmentPreview(attachment) && attachment.previewUrl != null
  const isPdf = isPdfAttachment(attachment)
  const isVideo = isVideoAttachment(attachment)
  const stateOverlay =
    attachment.state === "uploading" ? (
      <div className="absolute inset-0 flex items-center justify-center rounded-lg bg-black/25">
        <LoaderCircleIcon className="size-4 animate-spin text-white" />
      </div>
    ) : attachment.state === "failed" ? (
      <div
        role="button"
        tabIndex={0}
        aria-label="Retry upload"
        title={`Upload failed: ${attachment.error ?? "Upload failed"}`}
        onClick={(event) => {
          event.stopPropagation()
          onRetry?.(attachment.id)
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault()
            event.stopPropagation()
            onRetry?.(attachment.id)
          }
        }}
        className="absolute inset-0 flex flex-col items-center justify-center gap-1 rounded-lg bg-black/40 text-white outline-none"
      >
        <TriangleAlertIcon className="size-4 text-[var(--codevisor-status-warn)]" />
        <span className="text-[11px] font-medium">Retry</span>
      </div>
    ) : undefined

  return (
    <>
      <div className="group relative shrink-0">
        {visual ? (
          <VisualThumb
            name={attachment.name}
            isPdf={isPdf}
            isVideo={isVideo}
            imageUrl={attachment.previewUrl}
            overlay={stateOverlay}
            onClick={() =>
              setLightboxItem({
                mimeType: attachment.mimeType,
                name: attachment.name,
                url: attachment.previewUrl
              })
            }
          />
        ) : (
          <div className="relative">
            <FileChip name={attachment.name} />
            {stateOverlay}
          </div>
        )}
        {attachment.state === "uploaded" && (
          <span className="sr-only">{formatBytes(attachment.sizeBytes)}</span>
        )}
        {onRemove != null && (
          <button
            type="button"
            aria-label={`Remove ${attachment.name}`}
            title="Remove attachment"
            onClick={() => onRemove(attachment.id)}
            className="absolute top-1 right-1 flex size-4 cursor-default items-center justify-center rounded-full bg-black/[0.78] text-white opacity-0 outline-none ring-1 ring-white/85 group-hover:opacity-100"
          >
            <XIcon className="size-2" strokeWidth={3} />
          </button>
        )}
      </div>
      {lightboxItem != null && (
        <AttachmentLightbox item={lightboxItem} onClose={() => setLightboxItem(undefined)} />
      )}
    </>
  )
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(bytes < 10 * 1024 * 1024 ? 1 : 0)} MB`
}

// A non-focus-stealing anchored listbox above the textarea. Selection is
// keyboard-driven from the textarea itself (arrows/Return/Escape), exactly
// like the Swift slash popup — Base UI's Autocomplete owns its input, which
// is why this is a custom build.
function SlashCommandMenu({
  matches,
  selectedIndex,
  onAccept
}: {
  matches: readonly SlashCommand[]
  selectedIndex: number
  onAccept: (command: SlashCommand) => void
}) {
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const list = listRef.current
    if (list == null) return
    const selected = list.querySelector<HTMLElement>(`[data-index="${selectedIndex}"]`)
    selected?.scrollIntoView({ block: "nearest" })
  }, [selectedIndex])

  return (
    <div
      ref={listRef}
      role="listbox"
      aria-label="Slash commands"
      className={cn(
        "absolute bottom-full left-0 z-30 mb-2 max-h-[220px] w-full max-w-[520px] overflow-y-auto rounded-[10px] border p-1.5",
        "border-[var(--codevisor-separator)] bg-[var(--codevisor-composer-bg)] text-foreground shadow-[0_4px_12px_rgb(0_0_0/0.16)]"
      )}
    >
      {matches.map((command, index) => {
        const isSelected = index === selectedIndex
        return (
          <div
            key={command.name}
            role="option"
            aria-selected={isSelected}
            data-index={index}
            className={cn(
              "flex cursor-default items-center gap-2.5 rounded-md px-2.5 py-1.5 text-sm",
              isSelected && "bg-[var(--codevisor-accent)] text-white"
            )}
            onMouseDown={(mouseEvent) => {
              // Keep textarea focus; accepting is a click-through action.
              mouseEvent.preventDefault()
              onAccept(command)
            }}
          >
            <span className="font-medium">/{command.name}</span>
            <span
              className={cn(
                "text-muted-foreground min-w-0 flex-1 truncate",
                isSelected && "text-white/85"
              )}
            >
              {command.description}
            </span>
            {command.hint != null && (
              <span
                className={cn("text-muted-foreground/70 truncate", isSelected && "text-white/70")}
              >
                {command.hint}
              </span>
            )}
          </div>
        )
      })}
    </div>
  )
}
