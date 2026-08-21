/// The marketing-site top bar, shared by every page (landing, plugin
/// directory, plugin details) so navigation is identical everywhere. Fixed
/// with a blur backdrop — pages must pad their first content block below it.
export function SiteNav() {
  return (
    <header className="fixed inset-x-0 top-0 z-40 border-b border-hairline bg-black/80 backdrop-blur-xl">
      <nav className="mx-auto flex h-11 max-w-5xl items-center justify-between px-6 text-xs">
        <a href="/" className="flex items-center gap-2 font-semibold tracking-tight text-text">
          <img src="/codevisor-icon.png" alt="" className="size-6 rounded" />
          Codevisor
        </a>
        <div className="flex items-center gap-6 text-muted">
          <a href="/plugins" className="transition-colors hover:text-text">
            Plugins
          </a>
          <a href="/docs" className="transition-colors hover:text-text">
            Docs
          </a>
          <a
            href="/#install"
            className="rounded-full bg-text px-3 py-1 font-medium text-black transition-opacity hover:opacity-90"
          >
            Install
          </a>
        </div>
      </nav>
    </header>
  )
}
