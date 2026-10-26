import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router"
import { RootProvider } from "fumadocs-ui/provider/tanstack"
/// <reference types="vite/client" />

import { Analytics } from "../components/analytics"
import { fetchGitHubStars } from "../lib/github-stars"

import appCss from "../styles/app.css?url"

export const Route = createRootRoute({
  loader: async () => ({ githubStars: await fetchGitHubStars() }),
  staleTime: Number.POSITIVE_INFINITY,
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Codevisor — Run a whole crew of coding agents" },
      {
        name: "description",
        content:
          "Codevisor is a native Mac and iPhone app for Claude Code, Codex, Pi, and any ACP coding agent. Run agents side by side in isolated worktrees, on every machine you own."
      },
      { property: "og:title", content: "Codevisor" },
      {
        property: "og:description",
        content:
          "Run a whole crew of coding agents. Native on Mac and iPhone, running on every machine you own."
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
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
      </head>
      <body>
        <RootProvider>
          <Analytics />
          <Outlet />
        </RootProvider>
        <Scripts />
      </body>
    </html>
  )
}
