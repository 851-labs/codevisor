import { useCallback, useState } from "react"

// Minimal persisted state hook (the web analog of @AppStorage). Values are
// plain strings; callers narrow them.
export function useLocalStorage(
  key: string,
  defaultValue: string
): [string, (next: string) => void] {
  const [value, setValue] = useState<string>(() => {
    try {
      return window.localStorage.getItem(key) ?? defaultValue
    } catch {
      return defaultValue
    }
  })
  const set = useCallback(
    (next: string) => {
      setValue(next)
      try {
        window.localStorage.setItem(key, next)
      } catch {
        // Storage unavailable — keep in-memory state only.
      }
    },
    [key]
  )
  return [value, set]
}
