import type { ReactNode } from "react"

import { IPhonePro } from "./home-devices"
import { ThemedImage } from "./themed-image"

function BentoImage({
  name,
  alt,
  width,
  height,
  className
}: {
  name: string
  alt: string
  width: number
  height: number
  className: string
}) {
  return (
    <ThemedImage
      light={`/bento/${name}-light.webp`}
      dark={`/bento/${name}-dark.webp`}
      alt={alt}
      width={width}
      height={height}
      className={className}
    />
  )
}

function Render({
  name,
  width,
  height,
  alt,
  className = ""
}: {
  name: string
  width: number
  height: number
  alt: string
  className?: string
}) {
  return (
    <span className={`landing-render block w-full ${className}`} style={{ maxWidth: width }}>
      <BentoImage
        name={name}
        alt={alt}
        width={width}
        height={height}
        className="block h-auto w-full"
      />
    </span>
  )
}

function Card({ className = "", children }: { className?: string; children: ReactNode }) {
  return (
    <div
      className={`relative overflow-hidden rounded-(--landing-card-radius) border border-hairline bg-surface ${className}`}
    >
      {children}
    </div>
  )
}

function Label({ children, large = false }: { children: ReactNode; large?: boolean }) {
  return (
    <h3
      className={`relative z-10 text-center leading-tight font-semibold tracking-[-0.015em] text-balance ${
        large ? "text-[22px] sm:text-[26px] md:-mt-[5px]" : "text-[19px] sm:text-[21px]"
      }`}
    >
      {children}
    </h3>
  )
}

export function FeatureBento() {
  return (
    <div className="mt-10 grid grid-cols-1 gap-3 md:grid-flow-row-dense md:auto-rows-[minmax(250px,auto)] md:grid-cols-6">
      <Card className="min-h-[440px] p-6 sm:px-8 md:col-span-4 md:row-span-2">
        <Label large>iOS Simulator</Label>
        <BentoImage
          name="simulator-pane"
          alt="Codevisor's Simulator pane with an iPhone 18 Pro showing the emojis skin tone picker in Safari, and Device Settings open with Appearance set to Light"
          width={1058}
          height={752}
          className="absolute top-[51px] left-[-9px] w-[560px] max-w-none md:top-[46px] md:left-[-4px] md:w-[698px]"
        />
      </Card>

      <Card className="flex min-h-[250px] flex-col pt-6 md:col-span-2">
        <Label>Ghostty terminal</Label>
        <div className="relative mt-4 min-h-[170px] flex-1 overflow-hidden border-t border-hairline bg-[light-dark(#ffffff,#1e1e1e)]">
          <BentoImage
            name="ghostty-terminal"
            alt="Codevisor's Ghostty terminal running bun run dev in emojis, with Vite ready and serving localhost:3000"
            width={620}
            height={230}
            className="absolute top-5 left-6 h-auto w-[620px] max-w-none"
          />
        </div>
      </Card>

      <Card className="flex flex-col p-6 md:col-span-2">
        <div className="-mr-[100px] flex flex-1 items-center pb-5">
          <Render
            name="usage-limit"
            width={380}
            height={92}
            alt="Usage limit reached notice that resumes automatically, with Don't Resume and Switch Account buttons"
          />
        </div>
        <Label>Auto Resume Chats</Label>
      </Card>

      <Card className="h-[329px] p-6 md:col-span-2">
        <Label>Machine Stats</Label>
        <div className="mt-[18px] flex justify-center overflow-hidden">
          <Render
            name="inspector-machine"
            width={280}
            height={358}
            alt="Inspector Machine section: CPU at 47% during a build, GPU at 4%, 31.4 GB of 48 GB memory, disk usage, and uptime on an Apple M4 Pro"
            className="-mt-4"
          />
        </div>
      </Card>

      <Card className="h-[329px] p-6 md:col-span-2">
        <Label>Usage Limits</Label>
        <div className="mt-[19px] flex justify-center overflow-hidden">
          <Render
            name="inspector-usage"
            width={280}
            height={281}
            alt="Inspector Usage section: 5-hour, weekly, and weekly Fable limits, each with its usage and pace"
            className="-mt-4"
          />
        </div>
      </Card>

      <Card className="h-[329px] p-6 md:col-span-2">
        <Label>Context Window</Label>
        <div className="mt-[18px] flex justify-center overflow-hidden">
          <Render
            name="inspector-context"
            width={280}
            height={417}
            alt="Inspector Context section: 31% of a 200k context used, broken down into messages, system tools, system prompt, memory files, MCP tools, and skills"
            className="-mt-4"
          />
        </div>
      </Card>

      <Card className="relative h-[340px] p-6 sm:px-7 md:col-span-4">
        <Label>Automatic updates for agents &amp; servers</Label>
        <div className="absolute inset-0">
          <BentoImage
            name="settings-updates-window"
            alt="Codevisor Settings with Updates selected: one update available for Claude Code on This Mac, everything up to date on Mac Studio and VPS"
            width={892}
            height={724}
            className="absolute top-[63px] left-[-14px] w-[669px] max-w-none md:top-[42px] md:left-[calc(50%_-_334.5px)]"
          />
        </div>
      </Card>

      <Card className="h-[340px] p-6 md:col-span-2">
        <Label>iPhone &amp; iPad app</Label>
        <div className="mt-[17px] flex justify-center">
          <div className="w-[210px]" aria-hidden>
            <IPhonePro src="iphone-projects" alt="" />
          </div>
        </div>
      </Card>

      <Card className="min-h-[440px] p-6 sm:px-8 md:col-span-4 md:col-start-3 md:row-span-2 md:min-h-[540px]">
        <Label large>Sync your tools across machines</Label>
        <BentoImage
          name="settings-mcps-window"
          alt="Codevisor Settings with MCPs selected: Linear, Notion, and Sentry, each turned on for This Mac, Mac Studio, and VPS"
          width={892}
          height={724}
          className="absolute top-[76px] left-[-10px] w-[535px] max-w-none md:top-[39px] md:left-[-16px] md:w-[758px]"
        />
      </Card>

      <Card className="min-h-[280px] p-6 md:col-span-2 md:col-start-1">
        <Label>Automatic token rotation</Label>
        <BentoImage
          name="settings-accounts-window"
          alt="Codevisor's Claude Code Accounts sheet: alexandru@emojis.com in use, pondorasti@gmail.com ready to use, and Add Account"
          width={892}
          height={724}
          className="absolute top-[47px] left-[-78px] w-[491px] max-w-none md:top-[49px]"
        />
      </Card>

      <Card className="flex min-h-[250px] flex-col pt-6 md:col-span-2 md:col-start-1">
        <Label>Native notifications</Label>
        <div className="relative mt-5 min-h-[170px] flex-1">
          <BentoImage
            name="notifications"
            alt="macOS notification banners from Codevisor: Chat finished for Add emoji search, and Action required for Wire up the rack view"
            width={440}
            height={175}
            className="absolute inset-0 h-full w-full object-cover object-[30%_45%]"
          />
        </div>
      </Card>

      <Card className="flex flex-col p-6 sm:px-8 md:col-span-4">
        <div className="flex flex-1 items-center justify-center pb-6">
          <Render
            name="chrome-extension"
            width={460}
            height={296}
            alt="The Add Codevisor to Chrome card in a chat, with an Add to Chrome button that opens the Chrome Web Store"
          />
        </div>
        <Label>Browser Use in your own Chrome</Label>
      </Card>

      <Card className="flex flex-col p-6 md:col-span-2">
        <div className="flex flex-1 items-center justify-center pb-5">
          <Render
            name="worktree-picker"
            width={345}
            height={182}
            className="overflow-hidden rounded-xl border border-hairline"
            alt="The new chat Run in menu with New worktree selected, under the This Mac, emojis, and New worktree chips"
          />
        </div>
        <Label>A worktree for every chat</Label>
      </Card>

      <Card className="flex flex-col p-6 sm:px-7 md:col-span-3 md:h-[345px]">
        <Label>Computer Use</Label>
        <div className="mt-5 flex flex-1 items-end justify-center md:-mb-10">
          <Render
            name="computer-use"
            width={460}
            height={301}
            alt="The Allow Computer Use sheet with Accessibility and Screen Recording both granted"
          />
        </div>
      </Card>

      <Card className="min-h-[318px] p-6 sm:px-7 md:col-span-3 md:h-[345px] md:min-h-0">
        <Label>Completion Sounds</Label>
        <BentoImage
          name="settings-sounds-window"
          alt="Codevisor Settings with Notifications selected: Play sounds on, Glass for Chat finished, Hero for Action required"
          width={892}
          height={724}
          className="absolute bottom-[-163px] left-[-10px] w-[535px] max-w-none md:bottom-[-155px] md:left-[-7px] md:w-[556px]"
        />
      </Card>
    </div>
  )
}
