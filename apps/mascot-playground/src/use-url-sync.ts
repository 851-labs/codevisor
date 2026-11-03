import { useEffect, useMemo } from "react"

import type { PlaygroundState } from "./state.js"
import { stateToSearch } from "./url-state.js"

const urlDelayMs = 150

export function useUrlSync(state: PlaygroundState): void {
  const search = useMemo(() => stateToSearch(state), [state])

  useEffect(() => {
    const handle = setTimeout(() => history.replaceState(null, "", urlFor(search)), urlDelayMs)
    return () => clearTimeout(handle)
  }, [search])
}

const urlFor = (search: string): string => (search ? `?${search}` : location.pathname)
