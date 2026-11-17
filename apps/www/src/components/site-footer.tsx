import {
  CodevisorMark,
  DISCORD_INVITE_URL,
  DOWNLOAD_URL,
  GITHUB_REPO_URL,
  TESTFLIGHT_URL,
  X_URL
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
    heading: "Community",
    links: [
      { href: GITHUB_REPO_URL, label: "GitHub", external: true },
      { href: DISCORD_INVITE_URL, label: "Discord", external: true },
      { href: X_URL, label: "X / Twitter", external: true },
      { href: "/support", label: "Support" }
    ]
  }
]

const LEGAL_LINKS: FooterLink[] = [
  { href: "/terms", label: "Terms" },
  { href: "/privacy", label: "Privacy" }
]

function externalProps(link: FooterLink) {
  return link.external ? { target: "_blank", rel: "noreferrer" } : {}
}

export function SiteFooter() {
  return (
    <footer className="border-t border-hairline px-5 pt-16 pb-10 sm:px-8 sm:pt-20">
      <div className="grid grid-cols-2 gap-x-8 gap-y-12 sm:grid-cols-[1.4fr_repeat(3,1fr)]">
        <div className="col-span-2 sm:col-span-1">
          <a
            href="/"
            draggable={false}
            className="flex w-fit items-center gap-[5px] text-[16px] font-semibold tracking-[-0.015em]"
          >
            <CodevisorMark />
            Codevisor
          </a>
          <p className="mt-4 max-w-[260px] text-[14px] leading-relaxed text-pretty text-muted">
            Run a whole crew of coding agents, on every machine you own.
          </p>
        </div>
        {FOOTER_COLUMNS.map((column) => (
          <nav key={column.heading} aria-label={column.heading}>
            <h2 className="text-[14px] font-medium">{column.heading}</h2>
            <ul className="mt-4 space-y-3 text-[14px] text-muted">
              {column.links.map((link) => (
                <li key={link.href}>
                  <a
                    href={link.href}
                    {...externalProps(link)}
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
        <nav className="flex items-center gap-2" aria-label="Legal">
          {LEGAL_LINKS.map((link, index) => (
            <span key={link.href} className="flex items-center gap-2">
              {index > 0 && <span aria-hidden>·</span>}
              <a href={link.href} className="transition-colors hover:text-text">
                {link.label}
              </a>
            </span>
          ))}
        </nav>
      </div>
    </footer>
  )
}
