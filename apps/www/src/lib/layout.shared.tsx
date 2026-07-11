import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared"

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="flex items-center gap-2 font-semibold">
          <img src="/sheep.svg" alt="" className="size-4" />
          HerdMan Server
        </span>
      )
    },
    links: [
      { text: "Home", url: "/" },
      { text: "Download", url: "/download/macos" }
    ]
  }
}
