import type { ReactNode } from "react"

import { SiteFooter } from "./site-footer"
import { SiteNav } from "./site-nav"

export const plainLinkClass =
  "text-text underline decoration-hairline underline-offset-4 transition-colors hover:decoration-current"

export function SitePage({ children }: { children: ReactNode }) {
  return (
    <div className="landing min-h-screen overflow-x-clip bg-page text-text">
      <meta name="color-scheme" content="light dark" />
      <meta name="theme-color" media="(prefers-color-scheme: light)" content="#f5f5f7" />
      <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#151517" />
      <div className="mx-auto flex min-h-screen max-w-[1080px] flex-col border-x border-hairline">
        <SiteNav />
        <main className="flex-1">{children}</main>
        <SiteFooter />
      </div>
    </div>
  )
}

export function PageHero({
  eyebrow,
  title,
  description,
  className = "",
  children
}: {
  eyebrow?: ReactNode
  title?: ReactNode
  description?: ReactNode
  className?: string
  children?: ReactNode
}) {
  return (
    <section className={`px-5 pt-20 pb-16 text-center sm:px-8 sm:pt-28 ${className}`}>
      {eyebrow && <Eyebrow className="mb-5">{eyebrow}</Eyebrow>}
      {title && (
        <h1 className="mx-auto max-w-[640px] text-[40px] leading-[1.08] font-medium tracking-[-0.035em] sm:text-[64px]">
          {title}
        </h1>
      )}
      {description && (
        <p className="mx-auto mt-6 max-w-[520px] text-[15px] leading-relaxed text-muted">
          {description}
        </p>
      )}
      {children}
    </section>
  )
}

export function Eyebrow({ className = "", children }: { className?: string; children: ReactNode }) {
  return (
    <p className={`text-[13px] font-semibold tracking-[0.08em] text-signal uppercase ${className}`}>
      {children}
    </p>
  )
}

export function HeroButton({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a
      href={href}
      className="inline-flex h-12 items-center rounded-full bg-[light-dark(#161618,#f4f4f6)] px-7 text-[16px] font-semibold text-[light-dark(#ffffff,#111111)] transition-opacity hover:opacity-85"
    >
      {children}
    </a>
  )
}
