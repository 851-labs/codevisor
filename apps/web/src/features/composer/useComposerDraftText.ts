import { useCallback, useState } from "react"

const MAX_CACHED_COMPOSER_DRAFTS = 64
const composerDrafts = new Map<string, string>()

export function composerDraftText(key: string): string | undefined {
  return composerDrafts.get(key)
}

export function rememberComposerDraftText(key: string, text: string) {
  if (text === "") {
    composerDrafts.delete(key)
    return
  }
  composerDrafts.delete(key)
  composerDrafts.set(key, text)
  if (composerDrafts.size <= MAX_CACHED_COMPOSER_DRAFTS) return
  const oldest = composerDrafts.keys().next().value
  if (oldest != null) composerDrafts.delete(oldest)
}

// Mirrors the cached SessionController composerText on macOS: each session,
// plus the single new-chat draft, keeps unsent text while its route is unmounted.
export function useComposerDraftText(key: string, initialValue = "") {
  const [text, setTextState] = useState(() => composerDraftText(key) ?? initialValue)
  const setText = useCallback(
    (next: string) => {
      rememberComposerDraftText(key, next)
      setTextState(next)
    },
    [key]
  )
  return [text, setText] as const
}
