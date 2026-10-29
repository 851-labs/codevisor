import { DOWNLOAD_SECTION_URL } from "../components/header-kit"
import { HeroButton, PageHero, SitePage } from "../components/site-page"
import { FeatureBento } from "./home-bento"
import { DeviceTrio } from "./home-devices"
import { GetStarted } from "./home-get-started"
import { Worktrees } from "./home-worktrees"
import { SectionHead } from "./section-head"

const SHOW_WORKTREES = false

export function Home() {
  return (
    <SitePage>
      <Hero />
      {SHOW_WORKTREES && <Worktrees />}
      <Features />
      <GetStarted />
    </SitePage>
  )
}

function Hero() {
  return (
    <PageHero
      className="border-b border-hairline"
      title={
        <>
          The native home
          <br />
          for your coding agents.
        </>
      }
      description="Run Claude Code, Codex, Pi, and 30+ more side by side, each in its own worktree, on every machine you own, from your Mac or your iPhone."
    >
      <div className="mt-9 flex justify-center">
        <HeroButton href={DOWNLOAD_SECTION_URL}>Download</HeroButton>
      </div>
      <div className="relative mx-auto mt-[26px] max-w-[960px] sm:mt-5 md:max-w-[1016px]">
        <DeviceTrio
          ipad={{
            src: "ipad-conversation",
            alt: "Codevisor on iPad, with the sidebar grouped by machine beside the “Add skin tones to the picker” chat"
          }}
          mac={{
            src: "mac-conversation-desktop",
            alt: "Codevisor on Mac with the chat “Add skin tones to the picker” in the emojis project, and projects on This Mac, Mac Studio, and VPS in the sidebar"
          }}
          iphone={{
            src: "iphone-conversation",
            alt: "The same “Add skin tones to the picker” chat open in Codevisor on iPhone"
          }}
          eager
        />
      </div>
    </PageHero>
  )
}

function Features() {
  return (
    <section className="border-b border-hairline px-5 py-20 sm:px-8">
      <SectionHead eyebrow="Features" title="Everything you need to run coding agents." />
      <FeatureBento />
    </section>
  )
}
