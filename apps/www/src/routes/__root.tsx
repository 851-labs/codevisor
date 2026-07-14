/// <reference types="vite/client" />
import type { ReactNode } from "react"
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router"
import { RootProvider } from "fumadocs-ui/provider/tanstack"

import appCss from "../styles/app.css?url"

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Codevisor — Every coding agent. One app." },
      {
        name: "description",
        content:
          "Codevisor is a native macOS app that runs Claude Code, Codex, and any ACP coding agent on your machines — in one place."
      },
      { property: "og:title", content: "Codevisor" },
      {
        property: "og:description",
        content: "Every coding agent. One app. Native on macOS, remote on anything."
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://www.codevisor.dev" },
      { property: "og:image", content: "https://www.codevisor.dev/screenshots/chat.png" }
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/favicon.png", type: "image/png" }
    ]
  }),
  component: RootComponent
})

function RootComponent() {
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  )
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        <RootProvider>{children}</RootProvider>
        <Scripts />
      </body>
    </html>
  )
}
