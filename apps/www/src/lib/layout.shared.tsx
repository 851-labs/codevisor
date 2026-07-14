import type { BaseLayoutProps } from "fumadocs-ui/layouts/shared"

export function baseOptions(): BaseLayoutProps {
  return {
    nav: {
      title: (
        <span className="flex items-center gap-2 font-semibold">
          <img src="/codevisor-icon.png" alt="" className="size-4 rounded" />
          Codevisor Server
        </span>
      )
    },
    links: [
      { text: "Home", url: "/" },
      { text: "Install", url: "/#install" }
    ]
  }
}
