import type { ReactNode } from "react"

interface LegalPageProps {
  title: string
  description: string
  effectiveDate: string
  sectionsLabel: string
  sections: ReadonlyArray<{ id: string; title: string; body: ReactNode }>
}

export function LegalPage({
  title,
  description,
  effectiveDate,
  sectionsLabel,
  sections
}: LegalPageProps) {
  return (
    <div className="marketing-shell min-h-screen">
      <header className="border-b border-hairline">
        <nav className="mx-auto flex h-14 max-w-5xl items-center justify-between px-6 text-sm">
          <a href="/" className="flex items-center gap-2 font-semibold tracking-tight text-text">
            <img src="/codevisor-icon.png" alt="" className="size-7 rounded-md" />
            Codevisor
          </a>
          <a href="/" className="text-muted transition-colors hover:text-text">
            Back to Codevisor
          </a>
        </nav>
      </header>

      <main className="mx-auto max-w-5xl px-6 py-16 sm:py-24">
        <div className="border-b border-hairline pb-12">
          <p className="text-xs font-medium tracking-[0.18em] text-muted uppercase">
            Legal · Effective {effectiveDate}
          </p>
          <h1 className="mt-5 max-w-3xl text-4xl font-semibold tracking-[-0.035em] text-text sm:text-6xl">
            {title}
          </h1>
          <p className="mt-5 max-w-2xl text-lg leading-relaxed text-muted">{description}</p>
        </div>

        <div className="grid gap-14 pt-12 md:grid-cols-[180px_minmax(0,1fr)]">
          <aside className="hidden md:block">
            <nav className="sticky top-8 space-y-2 text-xs text-muted" aria-label={sectionsLabel}>
              {sections.map((section) => (
                <a
                  key={section.id}
                  href={`#${section.id}`}
                  className="block py-1 transition-colors hover:text-text"
                >
                  {section.title}
                </a>
              ))}
            </nav>
          </aside>

          <article className="min-w-0">
            {sections.map((section, index) => (
              <section
                key={section.id}
                id={section.id}
                className={
                  index === 0 ? "scroll-mt-8" : "mt-12 scroll-mt-8 border-t border-hairline pt-12"
                }
              >
                <h2 className="text-xl font-semibold tracking-tight text-text">{section.title}</h2>
                <div className="legal-copy mt-4 space-y-4 text-[15px] leading-7 text-muted">
                  {section.body}
                </div>
              </section>
            ))}
          </article>
        </div>
      </main>

      <footer className="border-t border-hairline px-6 py-8">
        <div className="mx-auto flex max-w-5xl flex-col items-center justify-between gap-4 text-xs text-muted sm:flex-row">
          <span>© {new Date().getFullYear()} 851 Inc.</span>
          <nav
            className="flex flex-wrap justify-center gap-x-5 gap-y-3"
            aria-label="Legal and contact"
          >
            <a href="/terms" className="transition-colors hover:text-text">
              Terms of Service
            </a>
            <a href="/privacy" className="transition-colors hover:text-text">
              Privacy Policy
            </a>
            <a href="mailto:hello@codevisor.dev" className="transition-colors hover:text-text">
              hello@codevisor.dev
            </a>
          </nav>
        </div>
      </footer>
    </div>
  )
}
