export function SiteFooter() {
  return (
    <footer className="border-t border-hairline px-6 py-10">
      <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-4 text-xs text-muted sm:flex-row">
        <span>© {new Date().getFullYear()} Codevisor LLC</span>
        <nav className="flex flex-wrap justify-center gap-x-5 gap-y-3" aria-label="Footer">
          <a href="/support" className="transition-colors hover:text-text">
            Support
          </a>
          <a href="/terms" className="transition-colors hover:text-text">
            Terms
          </a>
          <a href="/privacy" className="transition-colors hover:text-text">
            Privacy
          </a>
          <a href="/install.sh" className="transition-colors hover:text-text">
            install.sh
          </a>
        </nav>
      </div>
    </footer>
  )
}
