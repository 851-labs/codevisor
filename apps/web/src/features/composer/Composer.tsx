import { ArrowUpIcon, SquareIcon } from "lucide-react"
import { type KeyboardEvent, type ReactNode, useEffect, useMemo, useRef, useState } from "react"

import { cn } from "../../lib/cn"
import { type SlashCommand, slashMatchesFor, slashQueryFrom } from "./slash-commands"

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
  canSend,
  isSending = false,
  autoFocus = false,
  onSend,
  onStop
}: {
  value: string
  onValueChange: (next: string) => void
  placeholder?: string
  chips?: ReactNode
  commands?: readonly SlashCommand[]
  canSend?: boolean
  isSending?: boolean
  autoFocus?: boolean
  onSend: () => void
  onStop?: () => void
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null)
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
    textarea.style.height = `${Math.min(textarea.scrollHeight, 200)}px`
  }, [value])

  useEffect(() => {
    if (autoFocus) textareaRef.current?.focus()
  }, [autoFocus])

  const sendEnabled = (canSend ?? value.trim() !== "") || visibleMatches.length > 0

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
    if (value.trim() !== "") onSend()
  }

  const handleKeyDown = (keyEvent: KeyboardEvent<HTMLTextAreaElement>) => {
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
    }
    if (keyEvent.key === "Enter" && !keyEvent.shiftKey) {
      keyEvent.preventDefault()
      submitOrAcceptSlash()
    }
  }

  return (
    <div className="border-border-opaque bg-composer relative flex flex-col gap-2.5 rounded-2xl border p-3">
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
        onChange={(changeEvent) => onValueChange(changeEvent.target.value)}
        onKeyDown={handleKeyDown}
        className="placeholder:text-muted-foreground/70 max-h-[200px] w-full resize-none bg-transparent text-sm outline-none"
      />
      <div className="flex items-center gap-2.5">
        {chips}
        <span className="flex-1" />
        {isSending && onStop != null && (
          <button
            type="button"
            aria-label="Stop"
            title="Stop"
            onClick={onStop}
            className="text-muted-foreground hover:text-foreground border-border hover:bg-primary/5 flex size-7 cursor-default items-center justify-center rounded-full border outline-none"
          >
            <SquareIcon className="size-2.5 fill-current" />
          </button>
        )}
        <button
          type="button"
          aria-label="Send (↩)"
          title="Send (↩)"
          disabled={!sendEnabled}
          onClick={submitOrAcceptSlash}
          className={cn(
            "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
            sendEnabled
              ? "bg-primary/85 text-primary-foreground hover:bg-primary/95"
              : "bg-secondary text-muted-foreground/75"
          )}
        >
          <ArrowUpIcon className="size-3.5" strokeWidth={3} />
        </button>
      </div>
    </div>
  )
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
        "bg-[var(--herdman-popover-bg)] text-[var(--herdman-popover-fg)]",
        "border-[var(--herdman-popover-border)] shadow-[var(--herdman-popover-shadow)]"
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
              isSelected && "bg-primary text-primary-foreground"
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
                isSelected && "text-primary-foreground/85"
              )}
            >
              {command.description}
            </span>
            {command.hint != null && (
              <span
                className={cn(
                  "text-muted-foreground/70 truncate",
                  isSelected && "text-primary-foreground/70"
                )}
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
