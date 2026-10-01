import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router"
import { RootProvider } from "fumadocs-ui/provider/tanstack"
/// <reference types="vite/client" />
import type { ReactNode } from "react"

import { Analytics } from "../components/analytics"

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
          "Codevisor runs Claude Code, Codex, Pi, and any ACP coding agent on your Macs and Linux servers — from native apps for Mac and iPhone."
      },
      { property: "og:title", content: "Codevisor" },
      {
        property: "og:description",
        content: "Every coding agent. One app. Native on Mac and iPhone, running on any machine."
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://www.codevisor.dev" },
      { property: "og:image", content: "https://www.codevisor.dev/screenshots/og.png" }
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
        <RootProvider>
          <Analytics />
          {children}
        </RootProvider>
        <Scripts />
      </body>
    </html>
  )
}
