import { createRootRoute, Outlet } from "@tanstack/react-router"

import { ChromeRoot } from "../theme/ChromeRoot"
import { themeController } from "../theme/themeController"
import { ThemeProvider } from "../theme/ThemeProvider"
import { ThemeSourceProvider } from "../theme/ThemeSourceProvider"

export const Route = createRootRoute({
  component: RootComponent
})

function RootComponent() {
  return (
    <ThemeProvider attribute="class">
      <ThemeSourceProvider controller={themeController}>
        <ChromeRoot />
        <Outlet />
      </ThemeSourceProvider>
    </ThemeProvider>
  )
}
