const FOOTER_LINKS = [
  { href: "/docs", label: "Docs" },
  { href: "/support", label: "Support" },
  { href: "/terms", label: "Terms" },
  { href: "/privacy", label: "Privacy" },
  { href: "/install.sh", label: "install.sh" }
]

export function SiteFooter() {
  return (
    <footer className="flex flex-col items-center justify-between gap-4 border-t border-hairline px-5 py-10 text-xs text-muted sm:flex-row sm:px-8">
      <span>© {new Date().getFullYear()} Codevisor LLC</span>
      <nav className="flex flex-wrap justify-center gap-x-5 gap-y-3" aria-label="Footer">
        {FOOTER_LINKS.map((link) => (
          <a key={link.href} href={link.href} className="transition-colors hover:text-text">
            {link.label}
          </a>
        ))}
      </nav>
    </footer>
  )
}
