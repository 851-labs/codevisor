import type { ReactNode } from "react"

import { ThemedImage } from "../landing/themed-image"
import {
  CodevisorMark,
  DISCORD_INVITE_URL,
  DISCORD_LABEL,
  DiscordMark,
  DOWNLOAD_URL,
  GITHUB_REPO_URL,
  GitHubMark,
  TESTFLIGHT_URL,
  X_URL,
  XMark
} from "./header-kit"

type FooterLink = { href: string; label: string; external?: boolean }

const GOOGLE_OAUTH_VERIFICATION_LINK: FooterLink = {
  href: "/docs/plugins/gmail",
  label: "Gmail plugin"
}

const FOOTER_COLUMNS: { heading: string; links: FooterLink[] }[] = [
  {
    heading: "Product",
    links: [
      { href: DOWNLOAD_URL, label: "Download for Mac" },
      { href: TESTFLIGHT_URL, label: "iPhone beta", external: true },
      { href: "/plugins", label: "Plugins" },
      { href: "/docs/server", label: "Codevisor Server" }
    ]
  },
  {
    heading: "Resources",
    links: [
      { href: "/docs", label: "Docs" },
      { href: "/docs/api-reference", label: "API reference" },
      GOOGLE_OAUTH_VERIFICATION_LINK,
      { href: "/install.sh", label: "install.sh" }
    ]
  },
  {
    heading: "Company",
    links: [
      { href: "/support", label: "Support" },
      { href: "/privacy", label: "Privacy" },
      { href: "/terms", label: "Terms" }
    ]
  }
]

const SOCIAL_LINKS: { href: string; label: string; icon: ReactNode }[] = [
  { href: GITHUB_REPO_URL, label: "Codevisor on GitHub", icon: <GitHubMark className="size-5" /> },
  { href: DISCORD_INVITE_URL, label: DISCORD_LABEL, icon: <DiscordMark className="size-[22px]" /> },
  { href: X_URL, label: "Codevisor on X / Twitter", icon: <XMark className="size-5" /> }
]

function SanFranciscoMap() {
  return (
    <div className="relative isolate aspect-square w-9 shrink-0 rotate-6">
      <div className="absolute inset-0 rounded-lg bg-raised" />
      <ThemedImage
        light="/footer/san-francisco-map-light.webp"
        dark="/footer/san-francisco-map-dark.webp"
        alt="Map of San Francisco"
        width={200}
        height={200}
        className="absolute inset-0 rounded-lg select-none"
      />
      <div className="pointer-events-none absolute inset-0 rounded-lg ring-1 ring-[light-dark(rgba(0,0,0,0.1),rgba(255,255,255,0.1))] ring-inset" />
      <div className="absolute top-1/2 left-1/2 aspect-square w-2.5 -translate-x-1/2 -translate-y-1/2">
        <div className="absolute inset-0 animate-ping rounded-full bg-[light-dark(#3b82f6,#2563eb)] motion-reduce:hidden" />
        <div className="absolute inset-0 rounded-full border border-white bg-[light-dark(#3b82f6,#2563eb)]" />
      </div>
    </div>
  )
}

export function SiteFooter() {
  return (
    <footer className="border-t border-hairline px-5 pt-16 pb-10 sm:px-8 sm:pt-20">
      <div className="grid grid-cols-2 items-baseline gap-x-8 gap-y-12 sm:grid-cols-[1.4fr_repeat(3,1fr)]">
        <div className="col-span-2 sm:col-span-1">
          <a
            href="/"
            draggable={false}
            className="flex w-fit items-center gap-[5px] text-[16px] font-semibold tracking-[-0.015em]"
          >
            <CodevisorMark />
            <span className="self-baseline">Codevisor</span>
          </a>
          <p className="mt-4 max-w-[260px] text-[14px] leading-relaxed text-pretty text-muted">
            The perfect home for your Mac mini.
          </p>
          <nav className="mt-6 flex items-center gap-4" aria-label="Community">
            {SOCIAL_LINKS.map((social) => (
              <a
                key={social.href}
                href={social.href}
                target="_blank"
                rel="noreferrer"
                aria-label={social.label}
                className="text-muted transition-colors hover:text-text"
              >
                {social.icon}
              </a>
            ))}
          </nav>
        </div>
        {FOOTER_COLUMNS.map((column) => (
          <nav key={column.heading} aria-label={column.heading}>
            <h2 className="text-[14px] font-medium">{column.heading}</h2>
            <ul className="mt-4 space-y-3 text-[14px] text-muted">
              {column.links.map((link) => (
                <li key={link.href}>
                  <a
                    href={link.href}
                    {...(link.external && { target: "_blank", rel: "noreferrer" })}
                    className="transition-colors hover:text-text"
                  >
                    {link.label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>
        ))}
      </div>
      <div className="mt-16 flex flex-col-reverse gap-4 text-[13px] text-muted sm:mt-20 sm:flex-row sm:items-center sm:justify-between">
        <span>© {new Date().getFullYear()} Codevisor LLC</span>
        <div className="flex items-center gap-2.5">
          <span>Crafted with care in San Francisco</span>
          <SanFranciscoMap />
        </div>
      </div>
    </footer>
  )
}
