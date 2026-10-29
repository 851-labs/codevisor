import {
  DISCORD_INVITE_URL,
  DISCORD_LABEL,
  DiscordMark,
  DOWNLOAD_SECTION_URL,
  formatStars,
  GITHUB_REPO_URL,
  GitHubMark,
  githubLabel,
  useGitHubStars
} from "../components/header-kit"
import { FeatureBento } from "./home-bento"
import { DeviceTrio } from "./home-devices"
import { GetStarted } from "./home-get-started"
import { Worktrees } from "./home-worktrees"
import { SectionHead } from "./section-head"

const SHOW_WORKTREES = false

export function Home() {
  return (
    <div className="landing min-h-screen overflow-x-clip bg-page text-text">
      <meta name="color-scheme" content="light dark" />
      <meta name="theme-color" media="(prefers-color-scheme: light)" content="#f5f5f7" />
      <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#151517" />
      <div className="mx-auto max-w-[1080px] border-x border-hairline">
        <Header />
        <main>
          <Hero />
          {SHOW_WORKTREES && <Worktrees />}
          <Features />
          <GetStarted />
        </main>
        <Footer />
      </div>
    </div>
  )
}

const FOOTER_LINKS = [
  { href: "/docs", label: "Docs" },
  { href: "/support", label: "Support" },
  { href: "/terms", label: "Terms" },
  { href: "/privacy", label: "Privacy" },
  { href: "/install.sh", label: "install.sh" }
]

function Footer() {
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

const CODEVISOR_MARK_PATH =
  "M535.611 0.550235C581.985 0.550208 631.388 -5.7384 670.611 24.2045C676.265 28.5214 681.546 33.1385 686.183 38.5502C692.748 46.2132 698.705 54.5013 703.241 63.5502C721.545 100.069 715.611 144.957 715.611 184.55V246.55C715.611 264.832 714.622 284.813 700.522 298.376C680.728 317.415 646.586 311.55 621.611 311.55C575.208 311.55 528.806 312.648 487.611 337.155C472.166 346.343 457.779 357.975 448.433 373.55C444.183 380.633 440.45 389.056 441.871 397.55C447.374 430.452 487.954 425.786 511.611 420.95C556.483 411.777 600.591 401.547 646.611 401.55C667.495 401.551 691.418 403.293 705.001 421.55C711.679 430.525 713.618 440.729 714.777 451.55C716.996 472.275 715.611 493.699 715.611 514.55V627.55C715.611 644.795 716.581 662.561 713.162 679.55C708.513 702.65 693.802 724.787 673.611 737.086C665.875 741.799 657.358 745.359 648.611 747.67C635.167 751.21 621.389 750.55 607.611 750.55H553.611C533.943 750.55 514.667 750.66 499.9 735.379C483.229 718.129 484.954 692.871 477.175 671.55C460.897 626.933 421.779 598.312 374.611 595.643C326.724 592.934 282.383 630.275 266.782 673.55C258.411 696.768 261.077 723.256 239.611 739.871C236.233 742.486 232.549 744.661 228.611 746.319C211.847 753.371 191.384 750.55 173.611 750.55H105.611C80.9715 750.55 58.2983 750.94 36.6114 737.322C5.54739 717.813 -1.81445 682.479 0.521547 648.55C2.19857 624.21 9.35436 600.604 26.7813 582.639C49.2343 559.493 84.3215 550.552 114.611 543.076C137.864 537.338 161.195 531.439 184.611 526.553C216.798 519.837 249.506 514.097 280.611 503.346C306.285 494.473 332.051 482.68 350.183 461.55C357.076 453.517 363.491 445.05 368.241 435.55C385.22 401.591 382.611 363.387 382.611 326.55V135.55C382.611 94.8333 379.34 51.185 413.611 21.85C419.287 16.9922 425.866 12.5563 432.611 9.33539C441.683 5.00347 451.714 2.53267 461.611 0.989689C470.035 -0.323248 479.099 0.550235 487.611 0.550235H535.611ZM639.611 475.552C633.974 475.525 628.206 475.215 622.611 475.976C609.801 477.72 596.996 480.658 585.611 486.99C579.581 490.344 573.538 494.423 568.911 499.59C553.405 516.908 555.909 540.27 570.076 557.551C586.529 577.623 619.35 592.893 645.611 589.123C649.372 588.583 653.232 587.972 656.611 586.134C673.844 576.758 669.611 552.868 669.611 536.551C669.611 517.8 676.162 484.558 652.611 477.174C648.455 475.871 643.935 475.573 639.611 475.552ZM104.611 0.97797C112.442 -0.142952 120.714 0.550235 128.611 0.550235H225.611C238.594 0.550223 251.923 -0.201267 264.611 3.1557C286.214 8.87076 305.551 23.9824 316.299 43.5502C328.705 66.1372 327.611 90.6403 327.611 115.55V317.55C327.611 339.533 329.469 362.159 323.456 383.55C315.449 412.033 289.698 433.806 260.611 438.123C238.393 441.42 215.04 439.55 192.611 439.55H115.611C100.661 439.55 85.4373 440.436 70.6114 438.251C49.0994 435.08 28.9017 423.08 16.0997 405.55C0.872881 384.698 0.611391 361.197 0.611391 336.55V163.55C0.611381 139.208 -1.83538 113.491 3.06061 89.5502C9.91663 56.0213 35.5354 25.1915 66.6114 11.4125C78.9203 5.9546 91.3225 2.88096 104.611 0.97797Z"

function CodevisorMark() {
  return (
    <svg
      viewBox="0 0 716.53 751.11"
      className="h-4 w-auto shrink-0"
      fill="currentColor"
      aria-hidden
    >
      <path d={CODEVISOR_MARK_PATH} />
    </svg>
  )
}

function Header() {
  const stars = useGitHubStars()
  return (
    <header className="sticky top-0 z-40 flex h-14 items-center justify-between border-b border-hairline bg-page/80 px-5 text-[14px] backdrop-blur-xl backdrop-saturate-150 sm:px-8">
      <a
        href="/"
        draggable={false}
        className="flex items-center gap-[5px] text-[16px] font-semibold tracking-[-0.015em]"
      >
        <CodevisorMark />
        Codevisor
      </a>
      <nav className="flex items-center gap-4 sm:gap-5">
        <a
          href={GITHUB_REPO_URL}
          target="_blank"
          rel="noreferrer"
          aria-label={githubLabel(stars)}
          className="flex items-center gap-1 text-muted transition-colors hover:text-text"
        >
          <GitHubMark className="size-3.5" />
          <span className="tabular-nums">{stars === null ? "GitHub" : formatStars(stars)}</span>
        </a>
        <a
          href={DISCORD_INVITE_URL}
          target="_blank"
          rel="noreferrer"
          aria-label={DISCORD_LABEL}
          className="flex items-center gap-1.5 text-muted transition-colors hover:text-text"
        >
          <DiscordMark className="size-4" />
        </a>
        <a
          href={DOWNLOAD_SECTION_URL}
          className="rounded-full bg-[light-dark(#161618,#f4f4f6)] px-4 py-1.5 font-semibold text-[light-dark(#ffffff,#111111)] transition-opacity hover:opacity-85"
        >
          Download
        </a>
      </nav>
    </header>
  )
}

function Hero() {
  return (
    <section className="border-b border-hairline px-5 pt-20 pb-16 text-center sm:px-8 sm:pt-28">
      <h1 className="mx-auto max-w-[640px] text-[40px] leading-[1.08] font-medium tracking-[-0.035em] sm:text-[64px]">
        The native home
        <br />
        for your coding agents.
      </h1>
      <p className="mx-auto mt-6 max-w-[520px] text-[15px] leading-relaxed text-muted">
        Run Claude Code, Codex, Pi, and 30+ more side by side, each in its own worktree, on every
        machine you own, from your Mac or your iPhone.
      </p>
      <div className="mt-9 flex justify-center">
        <a
          href={DOWNLOAD_SECTION_URL}
          className="inline-flex h-12 items-center rounded-full bg-[light-dark(#161618,#f4f4f6)] px-7 text-[16px] font-semibold text-[light-dark(#ffffff,#111111)] transition-opacity hover:opacity-85"
        >
          Download
        </a>
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
    </section>
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
