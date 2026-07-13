import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { createRouter, RouterProvider } from "@tanstack/react-router"
import { StrictMode } from "react"
import ReactDOM from "react-dom/client"

import { type Api, ApiProvider } from "./lib/api"
import { CodevisorClient } from "./lib/client"
import { EventSocket } from "./lib/events"
import { wireServerEvents } from "./lib/queries"
import { resolveServerConfig } from "./lib/server-config"
import { routeTree } from "./routeTree.gen"
import "./styles/app.css"

const router = createRouter({ routeTree })

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}

// Resolve the server endpoint before first render: inside Tauri this asks the
// Rust side (which owns the sidecar server), in a browser it reads the env/
// localStorage overrides or falls back to same-origin (the vite /v1 proxy).
const config = await resolveServerConfig()
const api: Api = {
  config,
  client: new CodevisorClient(config),
  events: new EventSocket(config)
}
api.events.start()

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // The event feed keeps caches live; avoid focus-driven refetch storms.
      refetchOnWindowFocus: false,
      staleTime: 30_000
    }
  }
})
wireServerEvents(queryClient, api.events)

const rootElement = document.getElementById("root")
if (rootElement == null) throw new Error("Missing #root element")

ReactDOM.createRoot(rootElement).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ApiProvider api={api}>
        <RouterProvider router={router} />
      </ApiProvider>
    </QueryClientProvider>
  </StrictMode>
)
