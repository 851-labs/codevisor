import { isTauri } from "@tauri-apps/api/core"
import type { ComponentPropsWithoutRef, MouseEvent } from "react"

const supportedExternalProtocols = new Set(["http:", "https:", "mailto:", "tel:"])

export function isSupportedExternalUrl(href: string): boolean {
  try {
    return supportedExternalProtocols.has(new URL(href).protocol)
  } catch {
    return false
  }
}

async function openExternalUrl(href: string): Promise<void> {
  const { openUrl } = await import("@tauri-apps/plugin-opener")
  await openUrl(href)
}

export function ExternalLink({
  href,
  onClick,
  node: _node,
  ...props
}: ComponentPropsWithoutRef<"a"> & { node?: unknown }) {
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event)
    if (event.defaultPrevented || href == null) return
    if (!isSupportedExternalUrl(href)) {
      event.preventDefault()
      return
    }
    if (!isTauri()) return
    event.preventDefault()
    void openExternalUrl(href)
  }

  return <a {...props} href={href} target="_blank" rel="noreferrer" onClick={handleClick} />
}
