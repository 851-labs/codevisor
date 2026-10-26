import { useEffect, useRef, useState } from "react"
import type { ReactNode } from "react"

import { DOWNLOAD_SECTION_ID, DOWNLOAD_URL } from "../components/header-kit"
import { captureAnalytics } from "../lib/analytics"
import { DEVICE_SHADOW, IPhonePro, MacBookPro } from "./home-devices"
import { SectionHead } from "./section-head"

const LINUX_COMMAND = "curl -fsSL https://www.codevisor.dev/install.sh | sh"
const TESTFLIGHT_URL = "https://testflight.apple.com/join/qwsWkyxD"

function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false)
  const resetTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  useEffect(() => () => clearTimeout(resetTimer.current), [])
  const copy = () => {
    void navigator.clipboard
      .writeText(command)
      .then(() => {
        captureAnalytics({
          name: "www install command copied",
          properties: { method: "curl", placement: "get-started-linux" }
        })
        setCopied(true)
        clearTimeout(resetTimer.current)
        resetTimer.current = setTimeout(() => setCopied(false), 2000)
      })
      .catch(() => undefined)
  }
  return (
    <button
      type="button"
      onClick={copy}
      aria-label={`Copy command: ${command}`}
      className="landing-copy group flex h-10 w-full items-center gap-2 rounded-full border border-hairline bg-page pr-1.5 pl-4 text-left font-mono text-[11.5px] text-muted transition-colors hover:text-text"
    >
      <span className="landing-scroll-fade min-w-0 flex-1 overflow-x-auto whitespace-nowrap [scrollbar-width:none]">
        {command}
      </span>
      <span
        aria-live="polite"
        className="flex h-7 w-[78px] shrink-0 items-center justify-center gap-1 rounded-full bg-raised font-sans text-[11px] font-medium text-text"
      >
        {copied && (
          <svg viewBox="0 0 16 16" className="size-3 text-signal" fill="none" aria-hidden>
            <path
              d="m3.5 8.5 3 3 6-7"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            />
          </svg>
        )}
        {copied ? "Copied" : "Copy"}
      </span>
    </button>
  )
}

const SHOW_LINUX_TERMINAL = false

const XSERVE_PLACEMENT = SHOW_LINUX_TERMINAL
  ? "top-[-6px] left-[19px]"
  : "top-6 left-1/2 -translate-x-1/2"

function LinuxComposition() {
  return (
    <>
      <img
        draggable={false}
        src="/devices/xserve-g4.webp"
        alt="Xserve G4"
        width={1024}
        height={843}
        loading="lazy"
        className={`absolute h-auto w-[232px] max-w-none ${XSERVE_PLACEMENT}`}
      />
      {SHOW_LINUX_TERMINAL && (
        <img
          draggable={false}
          src="/bento/linux-install-dark.webp"
          alt="A Ghostty terminal on a Linux server running the Codevisor install script, ending with Finish onboarding later with codevisor setup"
          width={808}
          height={516}
          loading="lazy"
          className="absolute top-[40px] left-[135px] h-auto w-[606px] max-w-none drop-shadow-[0_16px_28px_rgba(0,0,0,0.4)]"
        />
      )}
    </>
  )
}

function PlatformCard({
  name,
  body,
  asset,
  children
}: {
  name: string
  body: string
  asset: ReactNode
  children: ReactNode
}) {
  return (
    <div className="flex flex-col overflow-hidden rounded-(--landing-card-radius) border border-hairline bg-surface">
      <div className="landing-noselect relative h-[220px] overflow-hidden border-b border-hairline bg-raised/60">
        {asset}
      </div>
      <div className="flex flex-1 flex-col p-5 sm:p-6">
        <h3 className="text-[17px] font-medium tracking-[-0.01em]">{name}</h3>
        <p className="mt-1.5 text-[14px] leading-relaxed text-muted">{body}</p>
        <div className="mt-6 flex flex-col gap-3 pt-0 md:mt-auto md:pt-6">{children}</div>
      </div>
    </div>
  )
}

function PrimaryAction({
  href,
  external = false,
  children
}: {
  href: string
  external?: boolean
  children: ReactNode
}) {
  return (
    <a
      href={href}
      {...(external ? { target: "_blank", rel: "noreferrer" } : {})}
      className="inline-flex h-10 w-fit items-center gap-2 rounded-full bg-[light-dark(#161618,#f4f4f6)] px-4 text-[14px] font-semibold text-[light-dark(#ffffff,#111111)] transition-opacity hover:opacity-85"
    >
      {children}
    </a>
  )
}

function AppleGlyph() {
  return (
    <svg viewBox="0 0 17 20" className="size-3.5" fill="currentColor" aria-hidden>
      <path d="M14.1 10.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.3-.9C3.7 4.8 2.1 5.8 1.2 7.3c-1.8 3.1-.5 7.7 1.3 10.3.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9-.1 0-2.8-1.1-2.8-4.2ZM11.6 3c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.3 2-1.1 3.1 1.1.1 2.3-.6 3.1-1.5Z" />
    </svg>
  )
}

export function GetStarted() {
  return (
    <section id={DOWNLOAD_SECTION_ID} className="scroll-mt-14 px-5 py-20 sm:px-8">
      <SectionHead eyebrow="Get started" title="Runs wherever you work." />
      <div className="mt-10 grid gap-3 md:grid-cols-3">
        <PlatformCard
          name="Mac"
          body="Native Swift app for Apple silicon."
          asset={
            <div className="absolute top-[-27.5px] left-[-56px] w-[853px]">
              <MacBookPro
                src="mac-conversation-desktop"
                alt="Codevisor on Mac with the chat “Add skin tones to the picker” open"
              />
            </div>
          }
        >
          <PrimaryAction href={DOWNLOAD_URL}>
            <AppleGlyph />
            Get macOS app
          </PrimaryAction>
        </PlatformCard>
        <PlatformCard
          name="iPhone & iPad"
          body="Every machine and chat, in your pocket."
          asset={
            <div className="absolute top-6 left-1/2 w-[200px] -translate-x-1/2">
              <IPhonePro
                src="iphone-projects"
                alt="Codevisor on iPhone listing projects on This Mac, Mac Studio, and VPS"
                className={DEVICE_SHADOW}
              />
            </div>
          }
        >
          <PrimaryAction href={TESTFLIGHT_URL} external>
            <AppleGlyph />
            Get iPhone &amp; iPad app
          </PrimaryAction>
        </PlatformCard>
        <PlatformCard
          name="Linux"
          body="Codevisor Server for x86-64 and arm64."
          asset={<LinuxComposition />}
        >
          <CopyCommand command={LINUX_COMMAND} />
        </PlatformCard>
      </div>
    </section>
  )
}
