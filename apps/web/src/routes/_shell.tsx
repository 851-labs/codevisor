import { isTauri } from "@tauri-apps/api/core"
import { createFileRoute, Outlet, redirect, useRouterState } from "@tanstack/react-router"

import { InternalSidebar } from "../features/internal/InternalSidebar"
import { Sidebar } from "../features/sidebar/Sidebar"
import { cn } from "../lib/cn"

function isOnboarded(): boolean {
  try {
    return window.localStorage.getItem("codevisor-onboarded") === "true"
  } catch {
    return false
  }
}

export const Route = createFileRoute("/_shell")({
  beforeLoad: () => {
    if (!isOnboarded()) {
      throw redirect({ to: "/onboarding" })
    }
  },
  component: ShellLayout
})

// The main split view: fixed sidebar column and the detail pane. Inside Tauri
// the window titlebar is a transparent overlay, so the top strip doubles as
// the drag region and the sidebar leaves room for the traffic lights.
function ShellLayout() {
  const inTauri = isTauri()
  const usesInternalSidebar = useRouterState({
    select: (state) => {
      const pathname = state.location.pathname
      return pathname.startsWith("/internal/") || pathname.startsWith("/verify/")
    }
  })
  return (
    <div className="relative flex h-full">
      {inTauri && <div data-tauri-drag-region className="absolute inset-x-0 top-0 z-40 h-9" />}
      <div
        className={cn(
          "border-border-opaque bg-sidebar w-[270px] shrink-0 border-r",
          inTauri && "pt-9"
        )}
      >
        {usesInternalSidebar ? <InternalSidebar /> : <Sidebar />}
      </div>
      <main className="bg-background min-w-0 flex-1">
        <Outlet />
      </main>
    </div>
  )
}
