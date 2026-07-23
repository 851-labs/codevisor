import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy — Codevisor" },
      {
        name: "description",
        content:
          "How Codevisor and its Chrome extension handle browser data when you use Browser Use."
      }
    ]
  }),
  component: PrivacyPolicy
})

const sections = [
  {
    id: "scope",
    title: "Scope",
    body: (
      <>
        <p>
          This policy describes how the Codevisor Chrome extension and the Codevisor desktop
          application handle information when you use Browser Use. The extension’s single purpose is
          to connect Codevisor to your existing Chrome session so an agent can complete browser
          tasks you request.
        </p>
        <p>
          Browser Use is optional. The extension does not operate as a standalone service and
          connects only to the Codevisor application running on your computer.
        </p>
      </>
    )
  },
  {
    id: "data",
    title: "Information Browser Use handles",
    body: (
      <>
        <p>Depending on your task, Browser Use may handle:</p>
        <ul>
          <li>Open-tab metadata, including page titles and URLs.</li>
          <li>Web history results when you or your agent explicitly searches Chrome history.</li>
          <li>
            Website content and resources needed to inspect or interact with a page, including text,
            images, links, form fields, and page structure.
          </li>
          <li>
            Browser actions and task artifacts, such as clicks, typed text, uploads, downloads,
            dialog responses, screenshots, and download metadata.
          </li>
          <li>
            Clipboard content only when a requested task reads from or writes to the clipboard.
          </li>
        </ul>
        <p>
          Pages, files, history results, or clipboard content you choose to use may contain personal
          identifiers, communications, authentication information, financial information, health
          information, location information, or other sensitive content. Codevisor handles that
          content only as needed for the task you requested.
        </p>
      </>
    )
  },
  {
    id: "use",
    title: "How information is used",
    body: (
      <>
        <p>
          The extension sends task data over a loopback connection to the Codevisor application on
          the same computer. Codevisor uses it to show browser state to the agent you selected and
          carry out the actions you requested.
        </p>
        <p>
          To provide an agent response, Codevisor may send relevant task instructions, page content,
          screenshots, and tool results to the AI model or agent provider you selected. The provider
          processes that information under its own terms and privacy policy. Codevisor may store
          conversations and tool results in its local database so you can return to your work.
        </p>
      </>
    )
  },
  {
    id: "sharing",
    title: "Sharing and limited use",
    body: (
      <>
        <p>
          We do not sell browser data, use it for advertising, or use it to determine
          creditworthiness or for lending. We use and transfer browser data only to provide the
          Browser Use feature, comply with applicable law, protect users and the service, or
          complete a corporate transaction permitted by applicable policy.
        </p>
        <p>
          Browser data may be shared with the AI model or agent provider you selected, and with a
          website or service when your requested task requires interacting with it. We do not permit
          employees or contractors to read browser content except with your explicit consent for
          support, when necessary for security, or when required by law.
        </p>
        <p>
          Codevisor’s use and transfer of information received from Google APIs complies with the
          Chrome Web Store User Data Policy, including its Limited Use requirements.
        </p>
      </>
    )
  },
  {
    id: "retention",
    title: "Storage and retention",
    body: (
      <>
        <p>
          The extension does not maintain a developer-operated cloud database. It keeps only the
          temporary connection and tab state needed for an active Browser Use session.
        </p>
        <p>
          Codevisor stores chat history and associated tool results locally until you remove them.
          AI model providers and websites involved in a task may retain information according to
          their own policies.
        </p>
      </>
    )
  },
  {
    id: "security",
    title: "Security",
    body: (
      <>
        <p>
          The extension accepts connections only from the Codevisor application through a loopback
          address on your computer. Chrome displays its debugging indicator while Codevisor controls
          a tab. Codevisor limits extension data handling to the functionality exposed by Browser
          Use and the permissions disclosed in the Chrome Web Store.
        </p>
      </>
    )
  },
  {
    id: "controls",
    title: "Your controls",
    body: (
      <>
        <p>You can stop or limit Browser Use at any time:</p>
        <ul>
          <li>Stop Browser Use from Codevisor.</li>
          <li>Choose Codevisor’s separate managed browser instead of your Chrome session.</li>
          <li>Disable or uninstall the Codevisor extension in Chrome.</li>
          <li>Remove local conversations and tool results from Codevisor.</li>
          <li>
            Manage Chrome history and operating-system clipboard content using their controls.
          </li>
        </ul>
      </>
    )
  },
  {
    id: "changes",
    title: "Changes and contact",
    body: (
      <>
        <p>
          We may update this policy as Browser Use changes. The effective date above identifies the
          current version.
        </p>
        <p>
          Questions or privacy requests can be sent to{" "}
          <a href="mailto:hello@codevisor.dev">hello@codevisor.dev</a>.
        </p>
      </>
    )
  }
] as const

function PrivacyPolicy() {
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
            Legal · Effective July 23, 2026
          </p>
          <h1 className="mt-5 max-w-3xl text-4xl font-semibold tracking-[-0.035em] text-text sm:text-6xl">
            Privacy, in plain language.
          </h1>
          <p className="mt-5 max-w-2xl text-lg leading-relaxed text-muted">
            Browser Use works with the pages and information you choose. This policy explains what
            moves through the Chrome extension, where it goes, and how you stay in control.
          </p>
        </div>

        <div className="grid gap-14 pt-12 md:grid-cols-[180px_minmax(0,1fr)]">
          <aside className="hidden md:block">
            <nav
              className="sticky top-8 space-y-2 text-xs text-muted"
              aria-label="Privacy sections"
            >
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
                <div className="privacy-copy mt-4 space-y-4 text-[15px] leading-7 text-muted">
                  {section.body}
                </div>
              </section>
            ))}
          </article>
        </div>
      </main>

      <footer className="border-t border-hairline px-6 py-8">
        <div className="mx-auto flex max-w-5xl items-center justify-between gap-4 text-xs text-muted">
          <span>© {new Date().getFullYear()} 851 Inc.</span>
          <a href="mailto:hello@codevisor.dev" className="transition-colors hover:text-text">
            hello@codevisor.dev
          </a>
        </div>
      </footer>
    </div>
  )
}
