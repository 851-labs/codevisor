import { useRouterState } from "@tanstack/react-router"
import { useEffect } from "react"

import { captureAnalytics } from "../lib/analytics"

export function Analytics() {
  const pathname = useRouterState({ select: (state) => state.location.pathname })

  useEffect(() => {
    captureAnalytics({ name: "$pageview", properties: { pathname } })
  }, [pathname])

  return null
}
