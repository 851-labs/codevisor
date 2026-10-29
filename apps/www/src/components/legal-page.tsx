import type { ReactNode } from "react"

import { PageHero, SitePage } from "./site-page"

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
    <SitePage>
      <PageHero
        className="border-b border-hairline"
        eyebrow={`Legal · Effective ${effectiveDate}`}
        title={title}
        description={description}
      />
      <section className="grid gap-14 px-5 py-20 sm:px-8 md:grid-cols-[200px_minmax(0,1fr)]">
        <aside className="hidden md:block">
          <nav
            className="sticky top-22 space-y-1 text-[13px] text-muted"
            aria-label={sectionsLabel}
          >
            {sections.map((section) => (
              <a
                key={section.id}
                href={`#${section.id}`}
                className="block py-1 leading-snug transition-colors hover:text-text"
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
                index === 0 ? "scroll-mt-20" : "mt-12 scroll-mt-20 border-t border-hairline pt-12"
              }
            >
              <h2 className="text-[19px] leading-tight font-semibold tracking-[-0.015em] sm:text-[21px]">
                {section.title}
              </h2>
              <div className="legal-copy mt-4 space-y-4 text-[15px] leading-relaxed text-muted">
                {section.body}
              </div>
            </section>
          ))}
        </article>
      </section>
    </SitePage>
  )
}
