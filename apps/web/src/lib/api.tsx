import { createContext, type ReactNode, useContext } from "react"

import type { CodevisorClient } from "./client"
import type { EventSocket } from "./events"
import type { ServerConfig } from "./server-config"

export interface Api {
  client: CodevisorClient
  events: EventSocket
  config: ServerConfig
}

const ApiContext = createContext<Api | undefined>(undefined)

export function ApiProvider({ api, children }: { api: Api; children: ReactNode }) {
  return <ApiContext.Provider value={api}>{children}</ApiContext.Provider>
}

export function useApi(): Api {
  const api = useContext(ApiContext)
  if (api == null) throw new Error("useApi must be used inside <ApiProvider>")
  return api
}
