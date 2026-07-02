/// <reference types="vite/client" />
import type { ReactNode } from "react"
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router"

import appCss from "../styles/app.css?url"

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "HerdMan — Run your coding agents in one place" },
      {
        name: "description",
        content:
          "HerdMan is a native macOS app for running your local ACP coding agents — Claude Code, Codex, and more — in one place, on your machines."
      },
      { property: "og:title", content: "HerdMan" },
      {
        property: "og:description",
        content: "Run your coding agents in one place. Native on macOS, remote on anything."
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://www.herdman.dev" }
    ],
    links: [
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Schibsted+Grotesk:ital,wght@0,400..900;1,400..900&family=Spline+Sans+Mono:wght@400;500&display=swap"
      },
      { rel: "stylesheet", href: appCss },
      { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" }
    ],
    scripts: [
      // Gates the scroll-reveal hiding in app.css so content stays visible
      // when JavaScript is unavailable.
      { children: "document.documentElement.classList.add('js')" }
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
    // The inline head script adds a "js" class before hydration; suppress the
    // expected class mismatch.
    <html lang="en" className="scheme-dark" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
